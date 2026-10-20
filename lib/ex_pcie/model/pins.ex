defmodule ExPcie.Model.Pins do
  @moduledoc """
  An agent that holds plain input values (configuration, run bits) and
  lets the test change them between cycles with `set/2`.
  """
  @behaviour ExPcie.Model.Agent
  defstruct values: %{}

  def new(values \\ %{}), do: %__MODULE__{values: Map.new(values)}
  def set(%__MODULE__{} = p, values), do: %{p | values: Map.merge(p.values, Map.new(values))}

  @impl true
  def drive(p, _), do: {p.values, p}

  @impl true
  def sample(p, _, _), do: p
end
