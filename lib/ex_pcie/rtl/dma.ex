defmodule ExPcie.RTL.Dma do
  @moduledoc """
  The two DMA channels (`ExPcie.RTL.H2c`, `ExPcie.RTL.C2h`) sharing the
  core's RQ and RC streams through `ExPcie.RTL.RqMux`.

  Ports: `rq` (master), `rc` (slave), `h2c_axis` (master stream, host to
  card), `c2h_axis` (slave stream, card to host), `cfg_max_payload`,
  `cfg_max_read_req`, and per channel (`h2c_`, `c2h_` prefix) the inputs
  `run`, `base`, `ring_bytes`, `period_bytes` and the outputs `ptr`,
  `irq`; `h2c_err_count`, `c2h_pkt_count`. See the channel modules for
  the semantics and constraints (aligned `base`, ring a multiple of the
  period, sizes multiples of 32 bytes).

  Completions are routed to the H2C channel (it issues the only reads);
  an RC packet with an unknown tag is counted there as an error.
  """
  use ExHdl.RTL
  alias ExPcie.RTL.{C2h, H2c, Ifc, RqMux}

  def build(opts \\ []) do
    module "pcie_dma" do
      rq = master(:rq, Ifc.rq())
      rc = slave(:rc, Ifc.rc())
      hs = master(:h2c_axis, Interface.axi_stream(data: 256, keep: false, last: false))
      cs = slave(:c2h_axis, Interface.axi_stream(data: 256, keep: false))
      mps = input(:cfg_max_payload, 3)
      mrrs = input(:cfg_max_read_req, 3)

      h = instance(:h, H2c.build())
      c = instance(:c, C2h.build(opts))
      x = instance(:x, RqMux.build())

      for {pfx, ch} <- [h2c: h, c2h: c] do
        ch.run <~ input(:"#{pfx}_run", 1)
        ch.base <~ input(:"#{pfx}_base", 64)
        ch.ring_bytes <~ input(:"#{pfx}_ring_bytes", 32)
        ch.period_bytes <~ input(:"#{pfx}_period_bytes", 32)
        output(:"#{pfx}_ptr", 32) <~ ch.ptr
      end

      output(:h2c_irq, 1) <~ h.irq
      output(:c2h_irq, 1) <~ c.irq
      output(:h2c_err_count, 16) <~ h.err_count
      output(:c2h_pkt_count, 16) <~ c.pkt_count

      h.cfg_max_read_req <~ mrrs
      c.cfg_max_payload <~ mps
      c.done <~ x.b_done

      connect(rc, h.rc)
      connect(h.m_axis, hs)
      connect(cs, c.s_axis)
      connect(h.rq, x.a)
      connect(c.rq, x.b)
      connect(x.rq, rq)
    end
  end
end
