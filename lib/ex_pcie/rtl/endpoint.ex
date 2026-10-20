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

  | Offset | Name | Access | Meaning |
  |---|---|---|---|
  | 0x000 | `ID` | ro | `0x50434945` |
  | 0x004 | `CAPS` | ro | `[7:0]` vectors, `[15:8]` stream bytes per beat |
  | 0x010 | `CTRL` | rw | bit 0 H2C run, bit 1 C2H run |
  | 0x014 | `STATUS` | w1c | bit 0 H2C period, 1 C2H period, 2 H2C error seen |
  | 0x020-0x02C | `H2C_BASE_LO/HI`, `H2C_RING`, `H2C_PERIOD` | rw | ring in host memory |
  | 0x030 | `H2C_PTR` | ro | bytes delivered, modulo ring |
  | 0x034 | `H2C_ERR` | ro | completion errors |
  | 0x040-0x04C | `C2H_BASE_LO/HI`, `C2H_RING`, `C2H_PERIOD` | rw | ring in host memory |
  | 0x050 | `C2H_PTR` | ro | bytes written, modulo ring |
  | 0x054 | `C2H_PKT` | ro | TLPs written |
  | 0x060 | `IRQ_FORCE` | pulse | raise the vectors in the written bits |
  | 0x064 | `IRQ_PENDING` | ro | pending vectors |
  | 0x068 | `BRIDGE_ERR` | ro | `[15:0]` UR completions, `[31:16]` dropped |
  | 0x06C | `AXIL_ERR` | ro | AXI-Lite error responses |
  | 0x1000 + 16 i | MSI-X table | rw | `ADDR_LO`, `ADDR_HI`, `DATA`, `CTRL` (bit 0 mask, reset 1) |
  | 0x2000 | PBA | ro | pending bits |

  With `loopback: true` the user streams are not exposed: the H2C
  stream feeds the C2H stream inside (a packet every four beats), a
  self-test of the whole path for board bring-up.

  Vector 0 is the H2C period, vector 1 the C2H period; further vectors
  (`vectors:` option) are only raised through `IRQ_FORCE`.
  Software starts a channel by writing base, ring and period, then the
  run bit; clearing the run bit resets it.
  """
  use ExHdl.RTL
  alias ExPcie.RTL.{AxilRegs, Bar0Bridge, Dma, Ifc, IrqCtrl}

  @id 0x50434945

  @doc "Register map entries for `AxilRegs`: `%{name, offset, kind, width}` (also used by host code)."
  def regs(vectors \\ 2) do
    base = [
      %{name: :id, offset: 0x000, kind: :ro},
      %{name: :caps, offset: 0x004, kind: :ro},
      %{name: :ctrl, offset: 0x010, kind: :rw, width: 2},
      %{name: :status, offset: 0x014, kind: :w1c, width: 3},
      %{name: :h2c_base_lo, offset: 0x020, kind: :rw},
      %{name: :h2c_base_hi, offset: 0x024, kind: :rw},
      %{name: :h2c_ring, offset: 0x028, kind: :rw},
      %{name: :h2c_period, offset: 0x02C, kind: :rw},
      %{name: :h2c_ptr, offset: 0x030, kind: :ro},
      %{name: :h2c_err, offset: 0x034, kind: :ro},
      %{name: :c2h_base_lo, offset: 0x040, kind: :rw},
      %{name: :c2h_base_hi, offset: 0x044, kind: :rw},
      %{name: :c2h_ring, offset: 0x048, kind: :rw},
      %{name: :c2h_period, offset: 0x04C, kind: :rw},
      %{name: :c2h_ptr, offset: 0x050, kind: :ro},
      %{name: :c2h_pkt, offset: 0x054, kind: :ro},
      %{name: :irq_force, offset: 0x060, kind: :pulse, width: vectors},
      %{name: :irq_pending, offset: 0x064, kind: :ro},
      %{name: :bridge_err, offset: 0x068, kind: :ro},
      %{name: :axil_err, offset: 0x06C, kind: :ro},
      %{name: :pba, offset: 0x2000, kind: :ro}
    ]

    table =
      for i <- 0..(vectors - 1),
          {n, o, k, w} <- [
            {:lo, 0, :rw, 32},
            {:hi, 4, :rw, 32},
            {:data, 8, :rw, 32},
            {:ctrl, 12, :rw, 1}
          ] do
        %{
          name: :"msix#{i}_#{n}",
          offset: 0x1000 + 16 * i + o,
          kind: k,
          width: w,
          reset: if(n == :ctrl, do: 1, else: 0)
        }
      end

    base ++ table
  end

  def build(opts \\ []) do
    vectors = Keyword.get(opts, :vectors, 2)
    loopback = Keyword.get(opts, :loopback, false)
    ab = 14
    regfile = AxilRegs.build("pcie_endpoint_regs_#{vectors}", regs(vectors), addr_bits: ab)

    module "pcie_endpoint_#{vectors}#{if loopback, do: "_loopback", else: ""}" do
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
      connect(br.m_axil, rf.s_axil)
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

      rf.id <~ @id
      rf.caps <~ (vectors ||| 32 <<< 8)
      dma.h2c_run <~ rf.ctrl[0]
      dma.c2h_run <~ rf.ctrl[1]

      for ch <- [:h2c, :c2h] do
        dma[:"#{ch}_base"] <~ cat([rf[:"#{ch}_base_hi"], rf[:"#{ch}_base_lo"]])
        dma[:"#{ch}_ring_bytes"] <~ rf[:"#{ch}_ring"]
        dma[:"#{ch}_period_bytes"] <~ rf[:"#{ch}_period"]
        rf[:"#{ch}_ptr"] <~ dma[:"#{ch}_ptr"]
      end

      rf.h2c_err <~ zext(dma.h2c_err_count, 32)
      rf.c2h_pkt <~ zext(dma.c2h_pkt_count, 32)

      err_prev = reg(:err_prev, 16)
      err_ev = wire(:err_ev, dma.h2c_err_count != err_prev)

      sync do
        err_prev <~ dma.h2c_err_count
      end

      rf.status_set <~ cat([err_ev, dma.c2h_irq, dma.h2c_irq])
      status_o <~ rf.status

      ic.req <~ (zext(cat([dma.c2h_irq, dma.h2c_irq]), vectors) ||| rf.irq_force)
      idx = 0..(vectors - 1)

      ic.tbl_addr
      <~ cat(for i <- Enum.reverse(idx), do: cat([rf[:"msix#{i}_hi"], rf[:"msix#{i}_lo"]]))

      ic.tbl_data <~ cat(for i <- Enum.reverse(idx), do: rf[:"msix#{i}_data"])
      ic.tbl_mask <~ cat(for i <- Enum.reverse(idx), do: rf[:"msix#{i}_ctrl"])
      rf.pba <~ zext(ic.pending, 32)
      rf.irq_pending <~ zext(ic.pending, 32)
      rf.bridge_err <~ cat([br.drop_count, br.ur_count])
      rf.axil_err <~ zext(br.axil_err_count, 32)
    end
  end
end
