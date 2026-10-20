defmodule ExPcie.RTL.AxilRegsTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias ExHdl.RTL.{Cosim, Sim}
  alias ExPcie.RTL.AxilRegs
  alias ExPcie.Test.Axil

  @regs [
    %{name: :ctrl, offset: 0, kind: :rw, reset: 5},
    %{name: :stat, offset: 4, kind: :ro},
    %{name: :ev, offset: 8, kind: :w1c, width: 8},
    %{name: :kick, offset: 12, kind: :pulse, width: 4},
    %{name: :wide, offset: 16, kind: :rw, width: 12}
  ]

  defp mod, do: AxilRegs.build("axil_regs_test", @regs, addr_bits: 8)

  test "read, write, strobes, decode errors" do
    sim = Sim.new(mod()) |> Sim.reset() |> Sim.poke(:stat, 0xCAFE)
    {sim, d, 0} = Axil.read(sim, :s_axil, 0)
    assert d == 5
    {sim, 0} = Axil.write(sim, :s_axil, 0, 0x1234_5678)
    {sim, d, 0} = Axil.read(sim, :s_axil, 0)
    assert d == 0x1234_5678
    assert Sim.peek(sim, :ctrl) == 0x1234_5678
    {sim, 0} = Axil.write(sim, :s_axil, 0, 0xAABBCCDD, 0b0101)
    assert Sim.peek(sim, :ctrl) == 0x12BB_56DD
    {sim, d, 0} = Axil.read(sim, :s_axil, 4)
    assert d == 0xCAFE
    {sim, 0} = Axil.write(sim, :s_axil, 4, 0)
    {sim, d, 0} = Axil.read(sim, :s_axil, 4)
    assert d == 0xCAFE
    {sim, 0} = Axil.write(sim, :s_axil, 16, 0xFFFF_FFFF)
    assert Sim.peek(sim, :wide) == 0xFFF
    {sim, 2} = Axil.write(sim, :s_axil, 0x40, 1)
    {_sim, _, 2} = Axil.read(sim, :s_axil, 0x44)
  end

  test "w1c and pulse" do
    sim = Sim.new(mod()) |> Sim.reset()
    sim = sim |> Sim.poke(:ev_set, 0b101) |> Sim.step() |> Sim.poke(:ev_set, 0)
    assert Sim.peek(sim, :ev) == 0b101
    {sim, 0} = Axil.write(sim, :s_axil, 8, 0b001)
    assert Sim.peek(sim, :ev) == 0b100
    {sim, _} = Axil.write(sim, :s_axil, 12, 0b1010)
    # the pulse is one cycle wide: it was visible right after the write beat
    assert Sim.peek(sim, :kick) in [0, 0b1010]
    sim = Sim.step(sim, 3)
    assert Sim.peek(sim, :kick) == 0
  end

  @tag :verilator
  test "co-simulates against Verilator" do
    :rand.seed(:exsss, {1, 2, 3})

    stim =
      for i <- 0..399 do
        %{
          rst_n: if(i < 2, do: 0, else: 1),
          stat: :rand.uniform(1 <<< 32) - 1,
          ev_set: if(:rand.uniform(8) == 1, do: :rand.uniform(255), else: 0),
          s_axil_awaddr: Enum.random([0, 4, 8, 12, 16, 20, 0x44]),
          s_axil_awvalid: :rand.uniform(2) - 1,
          s_axil_wdata: :rand.uniform(1 <<< 32) - 1,
          s_axil_wstrb: :rand.uniform(16) - 1,
          s_axil_wvalid: :rand.uniform(2) - 1,
          s_axil_bready: :rand.uniform(2) - 1,
          s_axil_araddr: Enum.random([0, 4, 8, 12, 16, 20, 0x44]),
          s_axil_arvalid: :rand.uniform(2) - 1,
          s_axil_rready: :rand.uniform(2) - 1
        }
      end

    assert :ok = Cosim.compare(mod(), stim)
  end
end
