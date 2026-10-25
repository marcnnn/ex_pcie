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

  @doc """
  The same arbiter for `n` producers: slave streams `s0` ... `s<n-1>`,
  `rq` (master), and `done` (`n` bits), bit `i` pulsing in the cycle the
  last beat of a packet from producer `i` is transferred on `rq`. With
  `n = 2` it is `build/0` with the ports renamed.
  """
  def build_n(n) when n >= 2 do
    mux = AXIS.packet_mux(n, data: Ifc.dw(), keep_bits: div(Ifc.dw(), 32), user: 62, src: false)

    module "pcie_rq_mux#{n}" do
      ss = for i <- 0..(n - 1), do: slave(:"s#{i}", Ifc.rq())
      rq = master(:rq, Ifc.rq())
      done = output(:done, n)

      m = instance(:m, mux)
      for {s, i} <- Enum.with_index(ss), do: connect(s, m[:"s#{i}_axis"])
      connect(m.m_axis, rq)
      done <~ m.done
    end
  end
end
