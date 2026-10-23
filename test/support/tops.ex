defmodule ExPcie.Test.Tops do
  @moduledoc "Test top levels combining the library's RTL blocks."
  use ExHdl.RTL
  alias ExPcie.RTL.{Bar0Bridge, Ifc}

  use ExHdl.Regs

  @doc "Register map of the bridge test: eight scratch registers, a read-only, a w1c and a pulse register."
  def bridge_map(ab \\ 12) do
    regmap "bridge_regs_file_#{ab}", addr_width: ab do
      for i <- 0..7 do
        register :"s#{i}", offset: 4 * i do
          field :value, 0..31, :rw
        end
      end

      register :ro_a, offset: 0x20 do
        field :value, 0..31, :ro
      end

      register :ev, offset: 0x24 do
        field :bits, 0..7, :w1c
      end

      register :kick, offset: 0x28, strobe: :write do
        field :bits, 0..3, :wo
      end
    end
  end

  @doc "Bar0Bridge in front of `bridge_map/1` (SLVERR for holes, like the endpoint)."
  def bridge_regs(ab \\ 12) do
    regfile = ExHdl.Regs.RTL.build(bridge_map(ab), unmapped: :slverr)

    module "bridge_regs_top_#{ab}" do
      cq = slave(:cq, Ifc.cq())
      cc = master(:cc, Ifc.cc())
      np = output(:cq_np_req, 2)
      ro_a = input(:ro_a, 32)
      ev_set = input(:ev_set, 8)
      ur = output(:ur_count, 16)
      drop = output(:drop_count, 16)
      aerr = output(:axil_err_count, 16)
      kick = output(:kick, 4)
      ev = output(:ev, 8)
      s = for i <- 0..7, do: output(:"s#{i}", 32)

      b = instance(:b, Bar0Bridge.build(addr_bits: ab))
      r = instance(:r, regfile)
      connect(cq, b.cq)
      connect(b.cc, cc)
      connect(b.m_axil, r.s_axil)
      np <~ b.cq_np_req
      ur <~ b.ur_count
      drop <~ b.drop_count
      aerr <~ b.axil_err_count
      r.ro_a_value <~ ro_a
      r.ev_bits_set <~ ev_set
      kick <~ (r.kick_bits &&& rep(r.kick_wr, 4))
      ev <~ r.ev_bits
      for i <- 0..7, do: Enum.at(s, i) <~ r[:"s#{i}_value"]
    end
  end

  @doc "The core's interrupt-related ports around an `IrqCtrl`: returns the instance with `cfg_*` ports as top ports."
  def irq_ports(ctrl) do
    rtl do
      for n <- [
            :cfg_msix_enable,
            :cfg_msix_mask,
            :cfg_msi_enable,
            :cfg_msix_sent,
            :cfg_msix_fail,
            :cfg_msi_sent,
            :cfg_msi_fail
          ] do
        ctrl[n] <~ input(n, 1)
      end

      output(:cfg_msix_int, 1) <~ ctrl.cfg_msix_int
      output(:cfg_msix_address, 64) <~ ctrl.cfg_msix_address
      output(:cfg_msix_data, 32) <~ ctrl.cfg_msix_data
      output(:cfg_msi_int, 32) <~ ctrl.cfg_msi_int
      output(:cfg_msi_pending_status, 32) <~ ctrl.cfg_msi_pending_status
      nil
    end
  end

  @doc "C2h behind RqMux (the other mux input is tied off)."
  def c2h do
    module "c2h_top" do
      s = slave(:s_axis, Interface.axi_stream(data: 256, keep: false))
      rq = master(:rq, Ifc.rq())
      run = input(:run, 1)
      base = input(:base, 64)
      ring = input(:ring_bytes, 32)
      period = input(:period_bytes, 32)
      mps = input(:cfg_max_payload, 3)
      ptr = output(:ptr, 32)
      cnt = output(:pkt_count, 16)

      c = instance(:c, ExPcie.RTL.C2h.build())
      m = instance(:m, ExPcie.RTL.RqMux.build())
      ic = instance(:ic, ExPcie.RTL.IrqCtrl.build(vectors: 1))
      irq_ports(ic)
      ic.req <~ c.irq
      ic.tbl_addr <~ input(:msix_addr, 64)
      ic.tbl_data <~ input(:msix_data, 32)
      ic.tbl_mask <~ 0
      output(:irq_pending, 1) <~ ic.pending
      output(:unused_a_tready, 1) <~ m.a.tready
      connect(s, c.s_axis)
      connect(c.rq, m.b)
      connect(m.rq, rq)
      for f <- [:tdata, :tkeep, :tlast, :tuser, :tvalid], do: m.a[f] <~ 0
      c.run <~ run
      c.base <~ base
      c.ring_bytes <~ ring
      c.period_bytes <~ period
      c.cfg_max_payload <~ mps
      c.done <~ m.b_done
      ptr <~ c.ptr
      cnt <~ c.pkt_count
    end
  end

  @doc "H2c behind RqMux (the other mux input is tied off)."
  def h2c(opts \\ []) do
    module "h2c_top" do
      m = master(:m_axis, Interface.axi_stream(data: 256, keep: false, last: false))
      rq = master(:rq, Ifc.rq())
      rc = slave(:rc, Ifc.rc())
      run = input(:run, 1)
      base = input(:base, 64)
      ring = input(:ring_bytes, 32)
      period = input(:period_bytes, 32)
      mrrs = input(:cfg_max_read_req, 3)
      ptr = output(:ptr, 32)
      err = output(:err_count, 16)

      h = instance(:h, ExPcie.RTL.H2c.build(opts))
      x = instance(:x, ExPcie.RTL.RqMux.build())
      ic = instance(:ic, ExPcie.RTL.IrqCtrl.build(vectors: 1))
      irq_ports(ic)
      ic.req <~ h.irq
      ic.tbl_addr <~ input(:msix_addr, 64)
      ic.tbl_data <~ input(:msix_data, 32)
      ic.tbl_mask <~ 0
      output(:irq_pending, 1) <~ ic.pending
      output(:unused_b_done, 1) <~ x.b_done
      output(:unused_a_tready, 1) <~ x.b.tready
      connect(h.m_axis, m)
      connect(h.rq, x.a)
      connect(x.rq, rq)
      connect(rc, h.rc)
      for f <- [:tdata, :tkeep, :tlast, :tuser, :tvalid], do: x.b[f] <~ 0
      h.run <~ run
      h.base <~ base
      h.ring_bytes <~ ring
      h.period_bytes <~ period
      h.cfg_max_read_req <~ mrrs
      ptr <~ h.ptr
      err <~ h.err_count
    end
  end
end
