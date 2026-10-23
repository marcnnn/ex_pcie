defmodule ExPcie.RTL.SynthTest do
  use ExUnit.Case, async: true

  alias ExHdl.Backends.SystemVerilog.RTL, as: SV
  alias ExPcie.RTL.{Bar0Bridge, C2h, Dma, Endpoint, H2c, IrqCtrl, RqMux}

  defp modules do
    [
      Bar0Bridge.build(),
      C2h.build(),
      H2c.build(),
      RqMux.build(),
      IrqCtrl.build(vectors: 4),
      Dma.build(),
      Endpoint.build(),
      Endpoint.build(loopback: true),
      Endpoint.build(
        extra: [
          %{name: :mixer, base: 0x4000, module: ExPcie.Test.MixerRegs.rtl()},
          %{name: :ext, base: 0x10000, size: 0x1000}
        ]
      ),
      ExPcie.Regs.rtl()
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
end
