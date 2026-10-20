defmodule ExPcie.RTL.Ifc do
  @moduledoc """
  The user-side streams of the UltraScale+ PCIe hard block as
  `ExHdl.RTL.Interface`s, 256-bit data (Gen3 x8, 250 MHz). All are seen
  from the producer (the master): the core produces CQ and RC, user logic
  produces CC and RQ. Widths follow `ExPcie.Axis.user_width/1`; `tkeep`
  has one bit per DWord.

  A module that is the completer declares `slave(:cq, Ifc.cq())` and
  `master(:cc, Ifc.cc())`; a requester `master(:rq, Ifc.rq())` and
  `slave(:rc, Ifc.rc())`. Ports are named `<prefix>_<field>`.
  """
  alias ExHdl.RTL.Interface

  @dw 256

  @doc "Data width in bits."
  def dw, do: @dw

  @doc "Completer request stream (core to user)."
  def cq, do: stream(:pcie_cq, 88)
  @doc "Completer completion stream (user to core)."
  def cc, do: stream(:pcie_cc, 33)
  @doc "Requester request stream (user to core)."
  def rq, do: stream(:pcie_rq, 62)
  @doc "Requester completion stream (core to user)."
  def rc, do: stream(:pcie_rc, 75)

  @doc "A PCIe user stream with `user` sideband bits."
  def stream(name, user, dw \\ @dw) do
    Interface.new(name, [
      {:tdata, dw, :fwd},
      {:tkeep, div(dw, 32), :fwd},
      {:tlast, 1, :fwd},
      {:tuser, user, :fwd},
      {:tvalid, 1, :fwd},
      {:tready, 1, :bwd}
    ])
  end
end
