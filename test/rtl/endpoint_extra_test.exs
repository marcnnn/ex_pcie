defmodule ExPcie.RTL.EndpointExtraTest do
  @moduledoc "More `defregs` slaves behind the endpoint's BAR0 through the AXI4-Lite interconnect."
  use ExUnit.Case, async: true

  alias ExPcie.Model.{Bench, Core, Pins}
  alias ExPcie.RTL.Endpoint
  alias ExPcie.Test.{MixerRegs, PtpRegs}

  @mixer 0x4000
  @ptp 0x8000

  defp extras do
    [
      %{name: :mixer, base: @mixer, module: MixerRegs.rtl()},
      %{name: :ptp, base: @ptp, module: PtpRegs.rtl()}
    ]
  end

  defp bench do
    Bench.new(
      Endpoint.build(loopback: true, extra: extras()),
      core: Core.new(seed: 2, cq_valid: 0.8, cc_ready: 0.8),
      pins: Pins.new(%{ptp_time_lo_value: 0x1234_5678})
    )
  end

  defp core(b), do: Bench.agent(b, :core)
  defp settle(b), do: b |> Bench.run_until(&Core.idle?(core(&1)), 5_000) |> Bench.run(10)
  defp write(b, off, v), do: Bench.update(b, :core, &Core.mmio_write(&1, off, v)) |> settle()

  defp read(b, off) do
    {c, tag} = Core.mmio_read(core(b), off)
    b = Bench.update(b, :core, fn _ -> c end) |> settle()
    {b, Core.mmio_result(core(b), tag)}
  end

  defp word({:ok, <<v::little-32>>, _}), do: v

  test "ports of the extra slaves are re-exported with their prefix" do
    m = Endpoint.build(extra: extras())
    names = MapSet.new(m.ports, & &1.name)

    for n <- [
          :mixer_ctrl_enable,
          :mixer_ctrl_mode,
          :mixer_gain_3_value,
          :mixer_irq_overflow_set,
          :ptp_time_lo_value,
          :ptp_adj_ppb,
          :ptp_adj_wr
        ],
        do: assert(n in names, "#{n}")

    refute :mixer_s_axil_awaddr in names
  end

  test "endpoint, mixer and PTP registers answer at their base addresses" do
    b = bench()
    {b, r} = read(b, ExPcie.Regs.offset(:id))
    assert word(r) == 0x50434945

    # reset values and writes of the mixer
    {b, r} = read(b, @mixer)
    assert word(r) == MixerRegs.reset_value(:ctrl)
    {b, r} = read(b, @mixer + MixerRegs.offset(:gain, 2))
    assert word(r) == 0x4000

    b = write(b, @mixer, MixerRegs.encode(:ctrl, mode: :stereo))
    assert Bench.output(b, :mixer_ctrl_mode) == 2
    assert Bench.output(b, :mixer_ctrl_enable) == 1
    b = write(b, @mixer + MixerRegs.offset(:gain, 3), 0xBEEF)
    assert Bench.output(b, :mixer_gain_3_value) == 0xBEEF
    {b, r} = read(b, @mixer + MixerRegs.offset(:gain, 3))
    assert word(r) == 0xBEEF

    # the PTP slave reads an input and drives an output
    {b, r} = read(b, @ptp + PtpRegs.offset(:time_lo))
    assert word(r) == 0x1234_5678
    b = write(b, @ptp + PtpRegs.offset(:adj), 0xFFFF_FF9C)
    assert Bench.output(b, :ptp_adj_ppb) == 0xFFFF_FF9C

    # the endpoint's own registers still work behind the interconnect
    b = write(b, ExPcie.Regs.offset(:h2c_ring), 4096)
    {b, r} = read(b, ExPcie.Regs.offset(:h2c_ring))
    assert word(r) == 4096
    assert Core.errors(core(b)) == []
  end

  test "unmapped addresses between and above the slaves fail the read, writes are counted" do
    b = bench()

    for off <- [0x5000, 0x8400, 0x9000, 0xFFFC] do
      {b2, r} = read(b, off)
      assert {:error, 4, _} = r, "0x#{Integer.to_string(off, 16)}"
      assert Core.errors(core(b2)) == []
    end

    b = write(b, 0x6000, 0xFFFF_FFFF)
    {b, r} = read(b, ExPcie.Regs.offset(:axil_err))
    assert word(r) >= 1
    {_b, r} = read(b, @mixer)
    assert word(r) == MixerRegs.reset_value(:ctrl)
  end

  test "an extra without a module exposes the AXI4-Lite master" do
    m = Endpoint.build(extra: [%{name: :ext, base: 0x10000, size: 0x1000}])
    names = MapSet.new(m.ports, & &1.name)
    assert :ext_axil_awaddr in names and :ext_axil_rdata in names
    assert {:u, 12} == Enum.find(m.ports, &(&1.name == :ext_axil_awaddr)).type
  end

  test "bad extras are rejected" do
    assert_raise ArgumentError, ~r/at or above 0x4000/, fn ->
      Endpoint.build(extra: [%{name: :x, base: 0x2000, module: PtpRegs.rtl()}])
    end

    assert_raise ArgumentError, ~r/multiple/, fn ->
      Endpoint.build(extra: [%{name: :x, base: 0x4100, module: MixerRegs.rtl()}])
    end
  end

  @tag :verilator
  test "Verilator replays an access trace through the interconnect" do
    b = bench()
    b = write(b, @mixer, 5)
    {b, _} = read(b, @ptp)
    b = write(b, @ptp + 4, 77)
    {b, _} = read(b, 0x6000)
    assert Bench.compare_verilator(b) == :ok
  end
end
