defmodule ExPcie.RTL.EndpointTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias ExPcie.Model.{Bench, Core}
  alias ExPcie.RTL.Endpoint

  @h2c_base 0x1_0000_0000
  @c2h_base 0x1_0010_0000
  @ring 2048
  @period 512
  @msix0 {0xFEE0_1000, 0x40}
  @msix1 {0xFEE0_2000, 0x41}

  defp reg(name) do
    Endpoint.regs() |> Enum.find(&(&1.name == name)) |> Map.fetch!(:offset)
  end

  defp host(b, f), do: Bench.update(b, :core, f)
  defp core(b), do: Bench.agent(b, :core)

  defp done_mmio(b),
    do: Bench.run_until(b, &Core.idle?(core(&1)), 5_000)

  defp read32(b, name) do
    {c, tag} = Core.mmio_read(core(b), reg(name))
    b = done_mmio(Bench.update(b, :core, fn _ -> c end))
    {:ok, <<v::little-32>>, _} = Core.mmio_result(core(b), tag)
    {b, v}
  end

  defp setup_bench(opts) do
    data = :rand.bytes(@ring)

    c =
      Core.new(
        Keyword.merge(
          [
            seed: 3,
            mps: 128,
            mrrs: 256,
            rc_valid: 0.8,
            cc_ready: 0.8,
            rq_ready: 0.8,
            cq_valid: 0.8,
            irq_latency: {1, 3}
          ],
          opts
        )
      )
      |> Core.put_mem(@h2c_base, data)

    {Bench.new(Endpoint.build(loopback: true), core: c), data}
  end

  defp program(b) do
    {a0, d0} = @msix0
    {a1, d1} = @msix1

    host(b, fn c ->
      c
      |> w(:msix0_lo, a0 &&& 0xFFFF_FFFF)
      |> w(:msix0_hi, a0 >>> 32)
      |> w(:msix0_data, d0)
      |> w(:msix0_ctrl, 0)
      |> w(:msix1_lo, a1 &&& 0xFFFF_FFFF)
      |> w(:msix1_hi, a1 >>> 32)
      |> w(:msix1_data, d1)
      |> w(:msix1_ctrl, 0)
      |> w(:h2c_base_lo, @h2c_base &&& 0xFFFF_FFFF)
      |> w(:h2c_base_hi, @h2c_base >>> 32)
      |> w(:h2c_ring, @ring)
      |> w(:h2c_period, @period)
      |> w(:c2h_base_lo, @c2h_base &&& 0xFFFF_FFFF)
      |> w(:c2h_base_hi, @c2h_base >>> 32)
      |> w(:c2h_ring, @ring)
      |> w(:c2h_period, @period)
      |> w(:ctrl, 3)
    end)
  end

  defp w(c, name, v), do: Core.mmio_write(c, reg(name), v)

  test "host programs the card over BAR0, loopback through both DMA channels, MSI-X per period" do
    :rand.seed(:exsss, {1, 2, 3})
    {b, data} = setup_bench([])
    {b, id} = read32(b, :id)
    assert id == 0x50434945
    b = program(b)
    b = Bench.run_until(b, &(length(Core.irq_log(core(&1))) >= 8), 40_000)
    c = core(b)

    assert Core.errors(c) == []
    # the C2H ring holds the stream the H2C ring delivered: identical to the source
    assert Core.read_mem(c, @c2h_base, @ring) == data

    vecs =
      c
      |> Core.irq_log()
      |> Enum.map(fn {_, {:msix, a, d}} -> {a, d} end)
      |> Enum.uniq()
      |> Enum.sort()

    assert vecs == Enum.sort([@msix0, @msix1])

    {b, ctrl} = read32(b, :ctrl)
    assert ctrl == 3
    {b, status} = read32(b, :status)
    assert (status &&& 3) == 3
    {b, ptr} = read32(b, :c2h_ptr)
    assert rem(ptr, 32) == 0 and ptr < @ring
    {b, pkts} = read32(b, :c2h_pkt)
    assert pkts > 0
    {b, h2c_err} = read32(b, :h2c_err)
    assert h2c_err == 0

    # stop: clearing run resets the channels; then write-1-to-clear empties the status
    b = host(b, &w(&1, :ctrl, 0)) |> done_mmio() |> Bench.run(60)
    {b, ptr} = read32(b, :c2h_ptr)
    assert ptr == 0
    b = host(b, &w(&1, :status, 7)) |> done_mmio()
    {b, status} = read32(b, :status)
    assert status == 0
    assert Bench.output(b, :status) == 0
  end

  test "software-forced interrupt and a masked vector" do
    {b, _} = setup_bench(irq_latency: {1, 1})
    {a0, d0} = @msix0

    b =
      host(b, fn c ->
        c
        |> w(:msix0_lo, a0)
        |> w(:msix0_hi, 0)
        |> w(:msix0_data, d0)
        |> w(:irq_force, 0b01)
      end)
      |> done_mmio()
      |> Bench.run(30)

    # vector 0 is masked after reset: pending, not sent
    {b, pend} = read32(b, :irq_pending)
    assert pend == 1
    {b, pba} = read32(b, :pba)
    assert pba == 1
    assert Core.irq_log(core(b)) == []

    # unmask: the pending interrupt fires
    b = host(b, &w(&1, :msix0_ctrl, 0)) |> done_mmio() |> Bench.run(30)
    assert [{_, {:msix, ^a0, ^d0}}] = Core.irq_log(core(b))
    {_b, pend} = read32(b, :irq_pending)
    assert pend == 0
  end

  test "interrupts survive failed delivery" do
    :rand.seed(:exsss, {4, 5, 6})
    {b, _} = setup_bench(irq_fail: 0.5, seed: 8)
    {a0, d0} = @msix0

    b =
      host(
        b,
        &(&1
          |> w(:msix0_lo, a0)
          |> w(:msix0_hi, 0)
          |> w(:msix0_data, d0)
          |> w(:msix0_ctrl, 0)
          |> w(:irq_force, 1))
      )

    b = Bench.run_until(b, &(Core.irq_log(core(&1)) != []), 2_000)
    assert Core.errors(core(b)) == []
  end

  @tag :verilator
  test "Verilator replays the full endpoint trace" do
    {b, _} = setup_bench([])
    b = program(b)
    b = Bench.run(b, 1500)
    assert Bench.compare_verilator(b) == :ok
  end
end
