defmodule ExPcie.RegsTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias ExHdl.Regs.SimDriver
  alias ExHdl.RTL.{Cosim, Sim}
  alias ExPcie.Regs

  # The BAR0 layout the host and the hardware agree on; it must not move.
  @layout [
    id: 0x000,
    caps: 0x004,
    ctrl: 0x010,
    timeout: 0x018,
    status: 0x014,
    h2c_base_lo: 0x020,
    h2c_base_hi: 0x024,
    h2c_ring: 0x028,
    h2c_period: 0x02C,
    h2c_ptr: 0x030,
    h2c_err: 0x034,
    c2h_base_lo: 0x040,
    c2h_base_hi: 0x044,
    c2h_ring: 0x048,
    c2h_period: 0x04C,
    c2h_ptr: 0x050,
    c2h_pkt: 0x054,
    irq_force: 0x060,
    irq_pending: 0x064,
    bridge_err: 0x068,
    axil_err: 0x06C,
    h2c_dbase_lo: 0x100,
    h2c_dbase_hi: 0x104,
    h2c_dsize: 0x108,
    h2c_dhead: 0x10C,
    h2c_dtail: 0x110,
    h2c_dstat: 0x114,
    h2c_wb_lo: 0x118,
    h2c_wb_hi: 0x11C,
    h2c_dctrl: 0x120,
    h2c_dcount: 0x124,
    h2c_dfetch: 0x128,
    c2h_dbase_lo: 0x140,
    c2h_dbase_hi: 0x144,
    c2h_dsize: 0x148,
    c2h_dhead: 0x14C,
    c2h_dtail: 0x150,
    c2h_dstat: 0x154,
    c2h_wb_lo: 0x158,
    c2h_wb_hi: 0x15C,
    c2h_dctrl: 0x160,
    c2h_dcount: 0x164,
    c2h_dfetch: 0x168,
    msix0_lo: 0x1000,
    msix0_hi: 0x1004,
    msix0_data: 0x1008,
    msix0_ctrl: 0x100C,
    msix1_lo: 0x1010,
    msix1_ctrl: 0x101C,
    msix7_data: 0x1078,
    pba: 0x2000
  ]

  test "the layout is the documented one" do
    for {name, off} <- @layout, do: assert(Regs.offset(name) == off, "#{name}")
    assert Regs.map().addr_width == 14
    assert Regs.map(8).registers |> length() > Regs.map(2).registers |> length()
  end

  test "host helpers" do
    assert Regs.encode(:ctrl, h2c_run: 1, c2h_run: 1) == 3
    assert Regs.decode(:status, 0b101) == %{h2c_period: 1, c2h_period: 0, h2c_error: 1}
    assert Regs.decode(:caps, 2 ||| 32 <<< 8) == %{vectors: 2, stream_bytes: 32, desc: 0}
    assert Regs.encode(:msix0_ctrl, []) == 1
    assert Regs.c_header() =~ "0x00000010"
    assert Regs.markdown() =~ "h2c_run"
  end

  defp driver(vectors, opts) do
    SimDriver.new(Sim.new(Regs.rtl(vectors)), opts)
  end

  test "constants, reset values, rw, w1c, strobe, holes" do
    d = driver(4, delays: 0..2, seed: 3)
    assert {0x50434945, :okay, d} = SimDriver.read(d, Regs.offset(:id))
    assert {c, :okay, d} = SimDriver.read(d, Regs.offset(:caps))
    assert Regs.decode(:caps, c) == %{vectors: 4, stream_bytes: 32, desc: 1}
    assert {1, :okay, d} = SimDriver.read(d, Regs.offset(:msix3_ctrl))

    {:okay, d} = SimDriver.write(d, Regs.offset(:ctrl), 3)
    assert SimDriver.peek(d, :ctrl_h2c_run) == 1
    assert SimDriver.peek(d, :ctrl_c2h_run) == 1
    {:okay, d} = SimDriver.write(d, Regs.offset(:h2c_ring), 0xFFFF_0000)
    assert {0xFFFF_0000, :okay, d} = SimDriver.read(d, Regs.offset(:h2c_ring))

    d = d |> SimDriver.poke(%{status_c2h_period_set: 1}) |> SimDriver.idle(1)
    d = d |> SimDriver.poke(%{status_c2h_period_set: 0}) |> SimDriver.idle(1)
    assert {2, :okay, d} = SimDriver.read(d, Regs.offset(:status))
    {:okay, d} = SimDriver.write(d, Regs.offset(:status), 2)
    assert {0, :okay, d} = SimDriver.read(d, Regs.offset(:status))

    # irq_force: the vector bits are on the outputs in the cycle `_wr` pulses
    {:okay, d} = SimDriver.write(d, Regs.offset(:irq_force), 0b0110)
    assert SimDriver.peek(d, :irq_force_vec) == 0b0110

    # holes and writes to read-only registers
    assert {0, :slverr, d} = SimDriver.read(d, 0x0200)
    {:slverr, d} = SimDriver.write(d, 0x0200, 1)
    {:okay, d} = SimDriver.write(d, Regs.offset(:h2c_ptr), 5)
    assert {0, :okay, _} = SimDriver.read(d, Regs.offset(:h2c_ptr))
  end

  @tag :verilator
  test "the slave co-simulates against Verilator" do
    d = driver(2, delays: 0..3, seed: 7)

    d =
      Enum.reduce(1..25, d, fn i, d ->
        addr = Enum.at(Map.values(Map.new(@layout)), rem(i * 5, length(@layout)))
        {_, d} = SimDriver.write(d, addr, i * 0x0101_0101, rem(i, 15) + 1)
        {_, _, d} = SimDriver.read(d, addr)
        d
      end)

    Cosim.assert_equivalent(Regs.rtl(2), SimDriver.stimulus(d))
  end
end
