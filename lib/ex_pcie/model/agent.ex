defmodule ExPcie.Model.Agent do
  @moduledoc """
  A participant of an `ExPcie.Model.Bench` run: something that drives some
  inputs of the design under test and watches some outputs, one clock
  cycle at a time.

  Per cycle the bench calls `drive/2` on every agent, pokes the merged
  inputs, reads the settled outputs, calls `sample/3` on every agent with
  them, then clocks. An agent must not make what it drives depend on the
  outputs of the same cycle (as an AXI-Stream source must not wait for
  `tready` before raising `tvalid`); transfers are decided in `sample/3`.
  """
  @callback drive(state :: term(), cycle :: non_neg_integer()) ::
              {%{atom() => integer()}, term()}
  @callback sample(state :: term(), outputs :: %{atom() => integer()}, cycle :: non_neg_integer()) ::
              term()
end
