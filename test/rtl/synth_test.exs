defmodule ExPcie.RTL.SynthTest do
  use ExUnit.Case, async: true

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExPcie.RTL.{Bar0Bridge, C2h, DescRing, Dma, Endpoint, H2c, IrqCtrl, RqMux}

  defp modules do
    [
      Bar0Bridge.build(),
      C2h.build(),
      H2c.build(),
      RqMux.build(),
      RqMux.build_n(4),
      RqMux.build_n(8),
      H2c.build(desc: true, timeout: :input),
      H2c.build(desc: true, timeout: :input, seg_last: true),
      H2c.build(desc: true, timeout: :input, pair: 1, pairs: 2, rc_shared: true, seg_last: true),
      H2c.build(desc: true, timeout: :input, pair: 3, pairs: 4, rc_shared: true),
      C2h.build(desc: true),
      DescRing.build(),
      DescRing.build(channel: 1, stop: false),
      DescRing.build(channel: 5),
      IrqCtrl.build(vectors: 4),
      Dma.build(),
      Dma.build(pairs: 2, seg_last: [1]),
      Endpoint.build(),
      Endpoint.build(loopback: true),
      Endpoint.build(pairs: 2, seg_last: [1]),
      Endpoint.build(pairs: 2, loopback: true),
      Endpoint.build(pairs: 4),
      Endpoint.build(
        extra: [
          %{name: :mixer, base: 0x4000, module: ExPcie.Test.MixerRegs.rtl()},
          %{name: :ext, base: 0x10000, size: 0x1000}
        ]
      ),
      ExPcie.Regs.rtl(),
      ExPcie.Regs.rtl(4, 2)
    ]
  end

  @tag :verilator
  test "every library module lints clean under verilator -Wall" do
    for m <- modules() do
      dir = Path.join(System.tmp_dir!(), "ex_pcie_lint_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      files =
        for {name, src} <- SV.generate(m),
            do: File.write!(Path.join(dir, name), src) && Path.join(dir, name)

      {out, status} =
        System.cmd("verilator", ["--lint-only", "-Wall", "--top-module", m.name] ++ files,
          stderr_to_stdout: true
        )

      File.rm_rf!(dir)
      assert status == 0, "#{m.name}:\n#{out}"
    end
  end

  @tag :yosys
  @tag timeout: 600_000
  test "the endpoint synthesises for UltraScale+ with the banks in block RAM or LUTRAM" do
    m = Endpoint.build()
    assert {:ok, u} = ExHdl.Synth.Yosys.utilization(SV.generate(m), m.name, family: "xcup")
    assert u.lut > 500 and u.ff > 500
    assert u.dsp == 0
    # the C2H buffer (64 x 256) maps to RAM, the H2C slot banks (8 x 64 x 32) too
    assert u.bram18 + u.lutram > 0
    IO.puts("endpoint xcup: #{inspect(Map.delete(u, :cells))}")
  end

  @tag :yosys
  @tag timeout: 900_000
  test "two channel pairs: resources against one pair" do
    util = fn m ->
      {:ok, u} = ExHdl.Synth.Yosys.utilization(SV.generate(m), m.name, family: "xcup")
      u
    end

    one = util.(Endpoint.build())
    two = util.(Endpoint.build(pairs: 2, seg_last: [1]))
    assert two.dsp == 0
    assert two.lut > one.lut and two.ff > one.ff
    # a second pair costs about what the first one does (the shared bridge, register file
    # and interrupt controller are small next to two channels and two descriptor rings)
    assert two.lut < 2 * one.lut and two.ff < 2 * one.ff

    IO.puts(
      "endpoint xcup pairs 1: #{inspect(Map.delete(one, :cells))}\n" <>
        "endpoint xcup pairs 2: #{inspect(Map.delete(two, :cells))}\n" <>
        "delta: LUT #{two.lut - one.lut}, FF #{two.ff - one.ff}"
    )
  end
end
