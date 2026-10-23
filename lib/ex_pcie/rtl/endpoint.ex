defmodule ExPcie.RTL.Endpoint do
  @moduledoc """
  The PCIe endpoint logic around the hard block's user streams: BAR0
  register access (`ExPcie.RTL.Bar0Bridge` into a register file), the
  two DMA channels (`ExPcie.RTL.Dma`) and interrupts
  (`ExPcie.RTL.IrqCtrl`, MSI-X table in BAR0).

  Ports: `cq`/`cc`/`rq`/`rc` streams (`ExPcie.RTL.Ifc`), `cq_np_req`,
  `cfg_max_payload`, `cfg_max_read_req`, the interrupt ports of
  `ExPcie.RTL.IrqCtrl`, and the user streams `h2c_axis` (master) and
  `c2h_axis` (slave).

  ## BAR0 register map (32-bit, byte offsets, 16 KiB)

  Declared in `ExPcie.Regs` (`defregs`-style map; the module has the table,
  `ExPcie.Regs.c_header/1` and `markdown/1` render it). Summary: `id` at
  0x000, `caps` 0x004, `ctrl` 0x010 (bit 0 H2C run, bit 1 C2H run),
  `status` 0x014 (w1c), the channel registers at 0x020 (H2C) and 0x040
  (C2H), `irq_force` 0x060, counters up to 0x06C, the MSI-X table at
  0x1000 + 16 i and the PBA at 0x2000.

  ## More register slaves behind the same BAR

  `extra:` is a list of `%{name: atom, base: byte offset, module: m}` where
  `m` is an AXI4-Lite slave module (`s_axil` bundle, e.g. the `rtl/0` of
  an `ExHdl.Regs` map) and `base` a multiple of its size
  (`2^address bits`) at or above 0x4000. The endpoint puts
  `ExHdlCores.AXIL.interconnect/2` between the BAR0 bridge and all slaves,
  instantiates each module and re-exports its other ports with the prefix
  `<name>_` (`mixer_ctrl_enable`, ...); clock and reset are shared. An
  entry without `module:` (but with `size:`) exposes the AXI4-Lite master
  bundle `<name>_axil` instead, for a slave elsewhere. The BAR0 aperture
  of the core must cover the highest range; accesses to unmapped
  addresses complete with SLVERR (read: Completer Abort), as holes inside
  the endpoint's own map. Without `extra:` the bridge drives the endpoint
  registers directly.

  With `loopback: true` the user streams are not exposed: the H2C
  stream feeds the C2H stream inside (a packet every four beats), a
  self-test of the whole path for board bring-up.

  Vector 0 is the H2C period, vector 1 the C2H period; further vectors
  (`vectors:` option) are only raised through `IRQ_FORCE`.
  Software starts a channel by writing base, ring and period, then the
  run bit; clearing the run bit resets it.
  """
  use ExHdl.RTL
  alias ExHdl.RTL.{Builder, Module}
  alias ExHdlCores.AXIL
  alias ExPcie.RTL.{Bar0Bridge, Dma, Ifc, IrqCtrl}
  alias ExPcie.Regs

  @core_size 0x4000

  @doc false
  # Normalised extra slaves: `%{name, base, size, module}`.
  def extras(list) do
    items =
      for e <- list do
        size =
          case e do
            %{module: %Module{} = m} ->
              m
              |> Module.port(:s_axil_awaddr)
              |> Map.fetch!(:type)
              |> elem(1)
              |> then(&Bitwise.bsl(1, &1))

            %{size: size} ->
              size
          end

        %{name: e.name, base: e.base, size: size, module: Map.get(e, :module)}
      end

    for e <- items,
        e.base < @core_size,
        do: raise(ArgumentError, "extra slave #{e.name}: base must be at or above 0x4000")

    items
  end

  def build(opts \\ []) do
    vectors = Keyword.get(opts, :vectors, 2)
    loopback = Keyword.get(opts, :loopback, false)
    extra = extras(Keyword.get(opts, :extra, []))

    ab =
      extra
      |> Enum.map(&(&1.base + &1.size))
      |> Enum.max(fn -> @core_size end)
      |> Builder.ceil_log2()
      |> max(14)

    regfile = Regs.rtl(vectors)

    xbar =
      if extra != [],
        do:
          AXIL.interconnect([%{base: 0, size: @core_size} | extra],
            addr_bits: ab,
            unmapped: :slverr
          )

    tag =
      if extra == [],
        do: "",
        else: "_x" <> Enum.map_join(extra, "_", &"#{&1.name}#{Integer.to_string(&1.base, 16)}")

    module "pcie_endpoint_#{vectors}#{if loopback, do: "_loopback", else: ""}#{tag}" do
      cq = slave(:cq, Ifc.cq())
      cc = master(:cc, Ifc.cc())
      rq = master(:rq, Ifc.rq())
      rc = slave(:rc, Ifc.rc())

      hs =
        if loopback,
          do: nil,
          else: master(:h2c_axis, Interface.axi_stream(data: 256, keep: false, last: false))

      cs =
        if loopback, do: nil, else: slave(:c2h_axis, Interface.axi_stream(data: 256, keep: false))

      np_req = output(:cq_np_req, 2)
      mps = input(:cfg_max_payload, 3)
      mrrs = input(:cfg_max_read_req, 3)
      status_o = output(:status, 3)

      br = instance(:br, Bar0Bridge.build(addr_bits: ab))
      rf = instance(:rf, regfile)
      dma = instance(:dma, Dma.build())
      ic = instance(:ic, IrqCtrl.build(vectors: vectors))

      for n <- [
            :cfg_msix_enable,
            :cfg_msix_mask,
            :cfg_msi_enable,
            :cfg_msix_sent,
            :cfg_msix_fail,
            :cfg_msi_sent,
            :cfg_msi_fail
          ] do
        ic[n] <~ input(n, 1)
      end

      output(:cfg_msix_int, 1) <~ ic.cfg_msix_int
      output(:cfg_msix_address, 64) <~ ic.cfg_msix_address
      output(:cfg_msix_data, 32) <~ ic.cfg_msix_data
      output(:cfg_msi_int, 32) <~ ic.cfg_msi_int
      output(:cfg_msi_pending_status, 32) <~ ic.cfg_msi_pending_status

      connect(cq, br.cq)
      connect(br.cc, cc)

      if xbar do
        x = instance(:xbar, xbar)
        connect(br.m_axil, x.s_axil)
        connect(x.m0_axil, rf.s_axil)

        for {e, n} <- Enum.with_index(extra, 1) do
          m = x[:"m#{n}_axil"]

          case e.module do
            nil ->
              connect(
                m,
                master(
                  :"#{e.name}_axil",
                  Interface.axi_lite(addr: Builder.ceil_log2(e.size), data: 32)
                )
              )

            mod ->
              inst = instance(:"u_#{e.name}", mod)
              connect(m, inst.s_axil)

              for p <- mod.ports,
                  p.role == :data,
                  not String.starts_with?("#{p.name}", "s_axil_") do
                port = :"#{e.name}_#{p.name}"

                if p.dir == :input,
                  do: inst[p.name] <~ input(port, p.type),
                  else: output(port, p.type) <~ inst[p.name]
              end
          end
        end
      else
        connect(br.m_axil, rf.s_axil)
      end

      np_req <~ br.cq_np_req
      connect(dma.rq, rq)
      connect(rc, dma.rc)

      if loopback do
        lb = reg(:lb_cnt, 2)
        dma.c2h_axis.tdata <~ dma.h2c_axis.tdata
        dma.c2h_axis.tvalid <~ dma.h2c_axis.tvalid
        dma.h2c_axis.tready <~ dma.c2h_axis.tready
        dma.c2h_axis.tlast <~ (lb == 3)

        sync do
          if dma.h2c_axis.tvalid and dma.c2h_axis.tready, do: lb <~ add_wrap(lb, 1)
        end
      else
        connect(dma.h2c_axis, hs)
        connect(cs, dma.c2h_axis)
      end

      dma.cfg_max_payload <~ mps
      dma.cfg_max_read_req <~ mrrs

      dma.h2c_run <~ rf.ctrl_h2c_run
      dma.c2h_run <~ rf.ctrl_c2h_run

      for ch <- [:h2c, :c2h] do
        dma[:"#{ch}_base"] <~ cat([rf[:"#{ch}_base_hi_value"], rf[:"#{ch}_base_lo_value"]])
        dma[:"#{ch}_ring_bytes"] <~ rf[:"#{ch}_ring_value"]
        dma[:"#{ch}_period_bytes"] <~ rf[:"#{ch}_period_value"]
        rf[:"#{ch}_ptr_value"] <~ dma[:"#{ch}_ptr"]
      end

      rf.h2c_err_value <~ zext(dma.h2c_err_count, 32)
      rf.c2h_pkt_value <~ zext(dma.c2h_pkt_count, 32)

      err_prev = reg(:err_prev, 16)
      err_ev = wire(:err_ev, dma.h2c_err_count != err_prev)

      sync do
        err_prev <~ dma.h2c_err_count
      end

      rf.status_h2c_period_set <~ dma.h2c_irq
      rf.status_c2h_period_set <~ dma.c2h_irq
      rf.status_h2c_error_set <~ err_ev
      status_o <~ cat([rf.status_h2c_error, rf.status_c2h_period, rf.status_h2c_period])

      ic.req
      <~ (zext(cat([dma.c2h_irq, dma.h2c_irq]), vectors) |||
            (rf.irq_force_vec &&& rep(rf.irq_force_wr, vectors)))

      idx = 0..(vectors - 1)

      ic.tbl_addr
      <~ cat(
        for i <- Enum.reverse(idx), do: cat([rf[:"msix#{i}_hi_value"], rf[:"msix#{i}_lo_value"]])
      )

      ic.tbl_data <~ cat(for i <- Enum.reverse(idx), do: rf[:"msix#{i}_data_value"])
      ic.tbl_mask <~ cat(for i <- Enum.reverse(idx), do: rf[:"msix#{i}_ctrl_mask"])
      rf.pba_value <~ zext(ic.pending, 32)
      rf.irq_pending_value <~ zext(ic.pending, 32)
      rf.bridge_err_ur <~ br.ur_count
      rf.bridge_err_dropped <~ br.drop_count
      rf.axil_err_value <~ zext(br.axil_err_count, 32)
    end
  end
end
