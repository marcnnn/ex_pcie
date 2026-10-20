defmodule ExPcie.Test.Axil do
  @moduledoc "A blocking AXI4-Lite master for the BEAM simulator (one transfer at a time)."
  alias ExHdl.RTL.Sim

  defp port(prefix, f), do: :"#{prefix}_#{f}"

  @doc "Writes `data` at `addr`; returns `{sim, bresp}`."
  def write(sim, prefix, addr, data, strb \\ 15) do
    p = &port(prefix, &1)

    sim =
      Sim.poke(sim, %{
        p.(:awaddr) => addr,
        p.(:awvalid) => 1,
        p.(:wdata) => data,
        p.(:wstrb) => strb,
        p.(:wvalid) => 1,
        p.(:bready) => 1
      })

    loop(sim, 100, fn sim ->
      aw = Sim.peek(sim, p.(:awready)) == 1
      w = Sim.peek(sim, p.(:wready)) == 1
      {sim, _} = {Sim.step(sim), nil}
      sim = if aw, do: Sim.poke(sim, p.(:awvalid), 0), else: sim
      sim = if w, do: Sim.poke(sim, p.(:wvalid), 0), else: sim
      {Sim.peek(sim, p.(:bvalid)) == 1, sim}
    end)
    |> then(fn sim ->
      resp = Sim.peek(sim, p.(:bresp))
      {sim |> Sim.step() |> Sim.poke(%{p.(:awvalid) => 0, p.(:wvalid) => 0}), resp}
    end)
  end

  @doc "Reads `addr`; returns `{sim, data, rresp}`."
  def read(sim, prefix, addr) do
    p = &port(prefix, &1)
    sim = Sim.poke(sim, %{p.(:araddr) => addr, p.(:arvalid) => 1, p.(:rready) => 1})

    sim =
      loop(sim, 100, fn sim ->
        ar = Sim.peek(sim, p.(:arready)) == 1
        sim = Sim.step(sim)
        sim = if ar, do: Sim.poke(sim, p.(:arvalid), 0), else: sim
        {Sim.peek(sim, p.(:rvalid)) == 1, sim}
      end)

    data = Sim.peek(sim, p.(:rdata))
    resp = Sim.peek(sim, p.(:rresp))
    {sim |> Sim.step() |> Sim.poke(p.(:arvalid), 0), data, resp}
  end

  defp loop(sim, 0, _), do: raise("AXI-Lite timeout") |> then(fn _ -> sim end)

  defp loop(sim, n, f) do
    case f.(sim) do
      {true, sim} -> sim
      {false, sim} -> loop(sim, n - 1, f)
    end
  end
end
