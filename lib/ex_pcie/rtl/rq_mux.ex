defmodule ExPcie.RTL.RqMux do
  @moduledoc """
  Packet-granular arbiter for two RQ producers onto the single RQ stream
  of the core, a thin wrapper around `ExHdlCores.AXIS.packet_mux/2`.
  Ports: `a` and `b` (slave `ExPcie.RTL.Ifc.rq/0` streams, prefixes `a`,
  `b`), `rq` (master). Once a packet has started it is forwarded to its
  `tlast`; between packets the producer that did not win last time has
  priority. The output goes through a register slice.

  `b_done` is a one-cycle pulse when the last beat of a packet from `b`
  is transferred on `rq`, i.e. accepted by the core; `ExPcie.RTL.C2h`
  uses it as the point after which its interrupt may be raised.
  """
  use ExHdl.RTL
  alias ExHdlCores.AXIS
  alias ExPcie.RTL.Ifc

  def build do
    mux = AXIS.packet_mux(2, data: Ifc.dw(), keep_bits: div(Ifc.dw(), 32), user: 62, src: false)

    module "pcie_rq_mux" do
      a = slave(:a, Ifc.rq())
      b = slave(:b, Ifc.rq())
      rq = master(:rq, Ifc.rq())
      b_done = output(:b_done, 1)

      m = instance(:m, mux)
      connect(a, m.s0_axis)
      connect(b, m.s1_axis)
      connect(m.m_axis, rq)
      b_done <~ m.done[1]
    end
  end
end
