defmodule ExPcie.RTL.RqMux do
  @moduledoc """
  Packet-granular arbiter for two RQ producers onto the single RQ stream
  of the core. Ports: `a` and `b` (slave `ExPcie.RTL.Ifc.rq/0` streams,
  prefixes `a`, `b`), `rq` (master). Once a packet has started it is
  forwarded to its `tlast`; between packets the producer that did not win
  last time has priority. The output goes through a register slice.

  `b_done` is a one-cycle pulse when the last beat of a packet from `b`
  is transferred on `rq`, i.e. accepted by the core; `ExPcie.RTL.C2h`
  uses it as the point after which its interrupt may be raised.
  """
  use ExHdl.RTL
  alias ExHdl.RTL.Examples
  alias ExPcie.RTL.Ifc

  def build do
    xif = Ifc.stream(:pcie_rq_x, 63)

    module "pcie_rq_mux" do
      a = slave(:a, Ifc.rq())
      b = slave(:b, Ifc.rq())
      rq = master(:rq, Ifc.rq())
      b_done = output(:b_done, 1)

      sel = reg(:sel, 2)
      last_a = reg(:last_a, 1)
      sk = instance(:sk, Examples.skid_buffer(xif))

      prefer_b = wire(:prefer_b, a.tvalid and b.tvalid and last_a)

      pick =
        wire(
          :pick,
          mux(
            prefer_b,
            const(2, 2),
            mux(a.tvalid, const(1, 2), mux(b.tvalid, const(2, 2), const(0, 2)))
          )
        )

      cur = wire(:cur, mux(sel != 0, sel, pick))
      is_a = wire(:is_a, cur == 1)
      is_b = wire(:is_b, cur == 2)
      ready = wire(:out_ready, sk.s_axis.tready)

      a.tready <~ (is_a and ready)
      b.tready <~ (is_b and ready)
      sk.s_axis.tvalid <~ ((is_a and a.tvalid) or (is_b and b.tvalid))
      sk.s_axis.tdata <~ mux(is_a, a.tdata, b.tdata)
      sk.s_axis.tkeep <~ mux(is_a, a.tkeep, b.tkeep)
      sk.s_axis.tlast <~ mux(is_a, a.tlast, b.tlast)
      sk.s_axis.tuser <~ cat([is_b, mux(is_a, a.tuser, b.tuser)])

      xfer = wire(:xfer, sk.s_axis.tvalid and ready)
      last = wire(:last, sk.s_axis.tlast)

      sync do
        if xfer do
          sel <~ mux(last, const(0, 2), cur)
          last_a <~ is_a
        end
      end

      rq.tdata <~ sk.m_axis.tdata
      rq.tkeep <~ sk.m_axis.tkeep
      rq.tlast <~ sk.m_axis.tlast
      rq.tuser <~ sk.m_axis.tuser[0..61]
      rq.tvalid <~ sk.m_axis.tvalid
      sk.m_axis.tready <~ rq.tready
      b_done <~ (sk.m_axis.tvalid and rq.tready and sk.m_axis.tlast and sk.m_axis.tuser[62])
    end
  end
end
