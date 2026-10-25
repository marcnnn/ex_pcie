defmodule ExPcie.RTL.DescRingTest do
  use ExUnit.Case, async: true

  alias ExPcie.DRing
  alias ExPcie.Model.{Bench, Core, Pins}
  alias ExPcie.Test.{RingEngine, Tops}

  @ring 0x3_0000_0000
  @wb 0x3_0001_0000

  defp setup_bench(descs, opts \\ []) do
    entries = Keyword.get(opts, :entries, 8)

    core =
      Core.new(
        seed: Keyword.get(opts, :seed, 1),
        rc_valid: 0.7,
        rq_ready: 0.7,
        latency: {3, 25},
        cuts: :random,
        error_reads: Keyword.get(opts, :error_reads, []),
        drop_reads: Keyword.get(opts, :drop_reads, [])
      )

    core =
      descs
      |> Enum.with_index()
      |> Enum.reduce(core, fn {{addr, len, flags}, i}, c ->
        Core.put_mem(c, @ring + 32 * i, DRing.encode(addr, len, flags, 0xC0DE0000 + i))
      end)

    pins =
      Pins.new(%{
        run: 1,
        dbase: @ring,
        dsize: entries,
        head: Keyword.get(opts, :head, length(descs)),
        wb_addr: @wb,
        wb_desc: Keyword.get(opts, :wb_desc, 1),
        wb_head: Keyword.get(opts, :wb_head, 1),
        irq_en: Keyword.get(opts, :irq_en, 1),
        timeout_cycles: Keyword.get(opts, :timeout, 0)
      })

    Bench.new(Tops.desc_ring(),
      core: core,
      pins: pins,
      eng: RingEngine.new(delay: Keyword.get(opts, :delay, 5))
    )
  end

  defp eng(b), do: Bench.agent(b, :eng)
  defp core(b), do: Bench.agent(b, :core)
  defp pins(b, v), do: Bench.update(b, :pins, &Pins.set(&1, v))

  defp descs(n),
    do:
      for(
        i <- 0..(n - 1),
        do: {0x7_0000_0000 + 0x100 * i, 32 * (i + 1), if(rem(i, 2) == 0, do: [:irq], else: [])}
      )

  test "fetches the ring in order, writes status and head back, interrupts on flagged descriptors" do
    d = descs(5)

    b =
      setup_bench(d) |> Bench.run_until(&(Bench.output(&1, :count) == 5), 3_000) |> Bench.run(40)

    assert [
             %{addr: 0x7_0000_0000, len: 32, irq: true},
             %{len: 64, irq: false},
             %{len: 96, irq: true},
             %{len: 128},
             %{len: 160, irq: true}
           ] = RingEngine.consumed(eng(b))

    assert eng(b).irqs == 3
    assert Bench.output(b, :tail) == 5
    assert Bench.output(b, :fetch) == 5
    assert Bench.output(b, :stat) == 0
    assert Core.errors(core(b)) == []

    for {{addr, len, _}, i} <- Enum.with_index(d) do
      desc = DRing.decode(Core.read_mem(core(b), @ring + 32 * i, 32))
      assert %{done: true, error: false, eop: false, bytes: ^len, addr: ^addr} = desc
      assert desc.cookie == 0xC0DE0000 + i
    end

    assert DRing.decode_head(Core.read_mem(core(b), @wb, 8)) == %{tail: 5, count: 5}
  end

  test "the interrupt follows the write-back; irq_en gates it" do
    b = setup_bench(descs(2), irq_en: 0) |> Bench.run(600)
    assert eng(b).irqs == 0
    assert Bench.output(b, :count) == 2

    b = setup_bench(descs(2), wb_desc: 0, wb_head: 0) |> Bench.run(600)
    assert eng(b).irqs == 1
    assert Core.stats(core(b)).rq_writes == 0
    assert Bench.output(b, :count) == 2
    assert Core.read_mem(core(b), @ring + 24, 8) == <<0::64>>
  end

  test "only the head block, only the status" do
    b = setup_bench(descs(3), wb_desc: 0) |> Bench.run(800)
    assert Core.stats(core(b)).rq_writes == 3
    assert DRing.decode_head(Core.read_mem(core(b), @wb, 8)) == %{tail: 3, count: 3}
    assert Core.read_mem(core(b), @ring + 24, 8) == <<0::64>>

    b = setup_bench(descs(3), wb_head: 0) |> Bench.run(800)
    assert Core.stats(core(b)).rq_writes == 3
    assert Core.read_mem(core(b), @wb, 8) == <<0::64>>
    assert %{done: true} = DRing.decode(Core.read_mem(core(b), @ring + 32, 32))
  end

  test "ring wrap: the doorbell moves, indices wrap at dsize" do
    d = descs(3)
    b = setup_bench(d, entries: 4)
    b = Bench.run_until(b, &(Bench.output(&1, :count) == 3), 3_000)
    assert Bench.output(b, :tail) == 3

    # two more descriptors: slot 3, then slot 0 again
    c =
      core(b)
      |> Core.put_mem(@ring + 96, DRing.encode(0x8_0000_0000, 64, [:irq]))
      |> Core.put_mem(@ring, DRing.encode(0x8_0000_1000, 96, []))

    b = Bench.update(b, :core, fn _ -> c end) |> pins(%{head: 1})
    b = Bench.run_until(b, &(Bench.output(&1, :count) == 5), 3_000) |> Bench.run(40)
    assert Bench.output(b, :tail) == 1
    assert Bench.output(b, :fetch) == 1

    assert [_, _, _, %{addr: 0x8_0000_0000}, %{addr: 0x8_0000_1000, len: 96}] =
             RingEngine.consumed(eng(b))

    assert DRing.decode_head(Core.read_mem(core(b), @wb, 8)) == %{tail: 1, count: 5}
  end

  test "no fetch until the doorbell moves" do
    b = setup_bench(descs(2), head: 0) |> Bench.run(200)
    assert RingEngine.consumed(eng(b)) == []
    assert Core.stats(core(b)).rq_reads == 0
    b = pins(b, %{head: 2}) |> Bench.run(500)
    assert length(RingEngine.consumed(eng(b))) == 2
  end

  test "the engine's slow reports back-pressure but lose nothing" do
    b =
      setup_bench(descs(7), delay: 40) |> Bench.run_until(&(Bench.output(&1, :count) == 7), 6_000)

    assert length(RingEngine.consumed(eng(b))) == 7
    assert Core.errors(core(b)) == []
  end

  test "a misaligned or empty descriptor halts the ring, earlier ones complete" do
    for bad <- [{0x7_0000_0010, 64, 0}, {0x7_0000_0000, 0, 0}, {0x7_0000_0000, 48, 0}] do
      d = [{0x7_0000_0000, 64, 0}, bad, {0x7_0000_0000, 64, 0}]
      b = setup_bench(d) |> Bench.run(900)
      assert Bench.output(b, :stat) == 0b011
      assert length(RingEngine.consumed(eng(b))) == 1
      assert Bench.output(b, :count) == 1
      assert Bench.output(b, :fetch) == 2
    end
  end

  test "a failed descriptor read halts the ring" do
    b = setup_bench(descs(3), error_reads: [@ring + 32]) |> Bench.run(900)
    assert Bench.output(b, :stat) == 0b101
    assert length(RingEngine.consumed(eng(b))) == 1
    assert Core.errors(core(b)) == []
  end

  test "an unanswered descriptor read times out; the register value 0 waits forever" do
    b = setup_bench(descs(3), drop_reads: [@ring + 64], timeout: 150) |> Bench.run(1_200)
    assert Bench.output(b, :stat) == 0b101
    assert length(RingEngine.consumed(eng(b))) == 2

    b = setup_bench(descs(3), drop_reads: [@ring + 64], timeout: 0) |> Bench.run(1_200)
    assert Bench.output(b, :stat) == 0
    assert length(RingEngine.consumed(eng(b))) == 2
    assert Bench.output(b, :fetch) == 3
  end

  test "run low resets the ring, indices restart" do
    b = setup_bench(descs(3)) |> Bench.run_until(&(Bench.output(&1, :count) == 3), 3_000)
    b = pins(b, %{run: 0}) |> Bench.run(10)
    assert {Bench.output(b, :tail), Bench.output(b, :count), Bench.output(b, :fetch)} == {0, 0, 0}
    b = pins(b, %{run: 1}) |> Bench.run_until(&(Bench.output(&1, :count) == 3), 3_000)
    assert length(RingEngine.consumed(eng(b))) == 6
  end

  test "random seeds, random ring sizes" do
    for seed <- 30..35 do
      :rand.seed(:exsss, {seed, 4, 4})
      n = Enum.random(3..9)

      d =
        for i <- 0..(n - 1),
            do: {0x7_0000_0000 + 0x40 * i, 32 * Enum.random(1..8), Enum.random([[], [:irq]])}

      b = setup_bench(d, entries: 16, seed: seed, delay: Enum.random(1..30))
      b = Bench.run_until(b, &(Bench.output(&1, :count) == n), 8_000) |> Bench.run(30)
      assert length(RingEngine.consumed(eng(b))) == n, "seed #{seed}"
      assert eng(b).irqs == Enum.count(d, fn {_, _, f} -> f != [] end), "seed #{seed}"
      assert Core.errors(core(b)) == []
      assert DRing.decode_head(Core.read_mem(core(b), @wb, 8)) == %{tail: n, count: n}
    end
  end

  @tag :verilator
  @tag timeout: 300_000
  test "Verilator replays the trace" do
    b = setup_bench(descs(6), seed: 3) |> Bench.run(900)
    assert Bench.compare_verilator(b) == :ok
  end
end
