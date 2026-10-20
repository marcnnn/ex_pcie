defmodule ExPcie.Model.Bench do
  @moduledoc """
  Closed-loop test bench: an `ExHdl.RTL.Sim` of a design plus
  `ExPcie.Model.Agent`s (the hard block model, stream sources and sinks,
  anything that implements the behaviour).

      bench = Bench.new(module, core: Core.new(), src: Source.new(:s_axis, beats))
      bench = Bench.run_until(bench, &done?/1, 5_000)
      Bench.agent(bench, :core) |> Core.errors()

  Cycle 0 and 1 apply reset (`rst_n` low, agents idle, `idle:` inputs
  held). Afterwards every cycle: agents `drive/2`, inputs are poked
  (inputs the design does not have are dropped), outputs read, agents
  `sample/3`, clock. The inputs of every cycle are recorded;
  `compare_verilator/1` replays exactly that stimulus in Verilator and
  checks all outputs match the BEAM simulation cycle by cycle.
  """
  alias ExHdl.RTL.{Cosim, Module, Sim}

  defstruct [:module, :sim, :inputs, :idle, agents: [], cycle: 0, trace: [], outputs: %{}]

  @doc "New bench. Agents are keyword entries `name: state`; the state's struct module is the agent. `idle:` are inputs held during reset."
  def new(%Module{} = mod, agents \\ [], opts \\ []) do
    inputs = for p <- mod.ports, p.dir == :input, p.role not in [:clock, :reset], do: p.name
    sim = Sim.new(mod, Keyword.take(opts, [:clocks]))

    %__MODULE__{
      module: mod,
      sim: sim,
      outputs: Sim.outputs(sim),
      inputs: MapSet.new(inputs),
      idle: Map.new(Keyword.get(opts, :idle, %{})),
      agents: agents
    }
  end

  @doc "State of agent `name`."
  def agent(%__MODULE__{agents: a}, name), do: Keyword.fetch!(a, name)

  @doc "Replaces the state of agent `name` with `f.(state)`."
  def update(%__MODULE__{} = b, name, f),
    do: %{b | agents: Keyword.update!(b.agents, name, f)}

  @doc "Value an output port had during the last cycle (before its clock edge)."
  def output(%__MODULE__{outputs: o}, name), do: Map.fetch!(o, name)

  @doc "Value of a signal after the last clock edge."
  def peek(%__MODULE__{sim: s}, name), do: Sim.peek(s, name)

  @doc "Current simulator (state after the last clock edge)."
  def sim(%__MODULE__{sim: s}), do: s

  @doc "Runs `n` cycles."
  def run(%__MODULE__{} = b, 0), do: b
  def run(%__MODULE__{} = b, n), do: b |> cycle() |> run(n - 1)

  @doc "Runs until `pred.(bench)` holds (checked before each cycle) or raises after `max` cycles."
  def run_until(%__MODULE__{} = b, pred, max) do
    cond do
      pred.(b) -> b
      b.cycle >= max -> raise "bench: condition not met within #{max} cycles"
      true -> b |> cycle() |> run_until(pred, max)
    end
  end

  @doc "One cycle."
  def cycle(%__MODULE__{cycle: n} = b) when n < 2 do
    ins = Map.merge(b.idle, %{rst_n: 0}) |> Map.take([:rst_n | MapSet.to_list(b.inputs)])
    step(b, ins, b.agents)
  end

  def cycle(%__MODULE__{} = b) do
    {ins, agents} =
      Enum.reduce(b.agents, {%{rst_n: 1}, []}, fn {name, st}, {ins, acc} ->
        {i, st} = st.__struct__.drive(st, b.cycle)
        {Map.merge(ins, i), [{name, st} | acc]}
      end)

    ins = Map.merge(b.idle, ins) |> Map.take([:rst_n | MapSet.to_list(b.inputs)])
    step(b, ins, Enum.reverse(agents))
  end

  defp step(b, ins, agents) do
    sim = Sim.poke(b.sim, ins)
    outs = Sim.outputs(sim)

    agents =
      if b.cycle < 2,
        do: agents,
        else: Enum.map(agents, fn {n, st} -> {n, st.__struct__.sample(st, outs, b.cycle)} end)

    %{
      b
      | sim: Sim.step(sim),
        agents: agents,
        cycle: b.cycle + 1,
        trace: [ins | b.trace],
        outputs: outs
    }
  end

  @doc "The recorded stimulus, oldest cycle first."
  def stimulus(%__MODULE__{trace: t}), do: Enum.reverse(t)

  @doc "Replays the recorded stimulus in Verilator; `:ok` or the first mismatch."
  def compare_verilator(%__MODULE__{} = b, opts \\ []),
    do: Cosim.compare(b.module, stimulus(b), opts)
end
