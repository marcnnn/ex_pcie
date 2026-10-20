defmodule ExPcie.RTL.C2hTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias ExPcie.Dma.Ref
  alias ExPcie.Model.{Bench, Core, Pins}
  alias ExPcie.Model.Stream.Source
  alias ExPcie.Test.Tops

  @base 0x1_2000_0000

  defp beats(seed, n_beats, max_pkt) do
    :rand.seed(:exsss, {seed, 1, 1})

    {out, _} =
      Enum.map_reduce(1..n_beats, 0, fn i, in_pkt ->
        len = in_pkt + 1
        last = len >= max_pkt or i == n_beats or :rand.uniform(4) == 1

        {%{tdata: :rand.uniform(1 <<< 256) - 1, tlast: if(last, do: 1, else: 0)},
         if(last, do: 0, else: len)}
      end)

    out
  end

  defp run_case(opts) do
    seed = Keyword.get(opts, :seed, 1)
    ring = Keyword.get(opts, :ring, 1024)
    period = Keyword.get(opts, :period, 256)
    base = Keyword.get(opts, :base, @base)
    mps = Keyword.get(opts, :mps, 128)
    src = beats(seed, Keyword.get(opts, :beats, 96), Keyword.get(opts, :max_pkt, 16))
    stream = Ref.stream_bytes(Enum.map(src, & &1.tdata))
    ppr = div(ring, period)
    ref_opts = [base: base, ring: ring, period: period, mps: mps]
    segs = Ref.c2h_segments(Enum.map(src, &(&1.tlast == 1)), ref_opts)

    # each interrupt must find its whole period already in host memory
    check = fn core, {_cycle, _what} ->
      i = length(core.irq_log)
      want = binary_part(stream, i * period, period)
      got = Core.read_mem(core, base + rem(i, ppr) * period, period)
      if got != want, do: raise("interrupt #{i} came before its period was in host memory")
    end

    core =
      Core.new(
        seed: seed,
        mps: mps,
        rq_ready: Keyword.get(opts, :rq_ready, 0.7),
        on_irq: check,
        irq_latency: {1, 1}
      )

    pins =
      Pins.new(%{
        run: 1,
        base: base,
        ring_bytes: ring,
        period_bytes: period,
        msix_addr: 0xFEE0_0000,
        msix_data: 0x4021
      })

    bench =
      Bench.new(Tops.c2h(),
        core: core,
        pins: pins,
        src: Source.new(:s_axis, src, valid: Keyword.get(opts, :valid, 0.8), seed: seed)
      )

    periods = div(byte_size(stream), period)

    bench =
      Bench.run_until(
        bench,
        &(Core.stats(Bench.agent(&1, :core)).rq_writes == length(segs) and
            length(Core.irq_log(Bench.agent(&1, :core))) >= periods),
        30_000
      )

    {bench, stream, segs, periods, ring}
  end

  defp written(core),
    do: for(%{kind: :mwr} = t <- Core.rq_log(core), do: {t.address, byte_size(t.data)})

  test "ring contents, TLP segmentation and one ordered interrupt per period" do
    {bench, stream, segs, periods, ring} = run_case(seed: 1)
    core = Bench.agent(bench, :core)
    assert Core.errors(core) == []
    assert written(core) == segs
    assert length(Core.irq_log(core)) == periods
    assert Core.read_mem(core, @base, ring) == Ref.c2h_ring(stream, ring)
    assert Bench.output(bench, :ptr) == rem(byte_size(stream), ring)
  end

  test "random configurations against the reference" do
    for seed <- 10..15 do
      :rand.seed(:exsss, {seed, 3, 3})
      mps = Enum.random([128, 256, 512])
      period = Enum.random([64, 128, 256, 512])
      ring = period * Enum.random([2, 3, 4])
      base = 0x4_0000_0000 + 32 * :rand.uniform(200)

      {bench, stream, segs, _, _} =
        run_case(
          seed: seed,
          mps: mps,
          period: period,
          ring: ring,
          base: base,
          beats: 80,
          max_pkt: Enum.random([3, 16, 40]),
          valid: Enum.random([0.3, 1.0]),
          rq_ready: Enum.random([0.4, 1.0])
        )

      core = Bench.agent(bench, :core)
      assert Core.errors(core) == [], "seed #{seed}"
      w = written(core)

      if w != segs,
        do:
          flunk(
            "seed #{seed}: got #{inspect(w)}\nwant #{inspect(segs)}\nmps #{mps} period #{period} ring #{ring} base #{base}"
          )

      got = Core.read_mem(core, base, ring)
      want = Ref.c2h_ring(stream, ring)

      if got != want do
        i = Enum.find(0..(ring - 1), &(:binary.at(got, &1) != :binary.at(want, &1)))

        flunk(
          "seed #{seed}: ring differs at #{i} total #{byte_size(stream)} ring #{ring} mps #{mps} period #{period}"
        )
      end
    end
  end

  test "4 KiB boundary splits a TLP" do
    {bench, stream, segs, _, ring} =
      run_case(
        seed: 2,
        mps: 256,
        base: 0x8000_0000 + 4096 - 96,
        ring: 2048,
        period: 1024,
        max_pkt: 32,
        beats: 128,
        valid: 1.0,
        rq_ready: 1.0
      )

    core = Bench.agent(bench, :core)
    assert Core.errors(core) == []
    assert {0x8000_0000 + 4096 - 96, 96} in segs
    assert written(core) == segs
    assert Core.read_mem(core, 0x8000_0000 + 4096 - 96, ring) == Ref.c2h_ring(stream, ring)
  end

  test "restart: clearing run resets the ring to offset 0" do
    src = beats(7, 24, 4)
    core = Core.new(seed: 7, rq_ready: 1.0, irq_latency: {1, 1})

    pins =
      Pins.new(%{
        run: 1,
        base: @base,
        ring_bytes: 1024,
        period_bytes: 256,
        msix_addr: 1,
        msix_data: 1
      })

    bench =
      Bench.new(Tops.c2h(), core: core, pins: pins, src: Source.new(:s_axis, src, valid: 1.0))

    bench =
      Bench.run_until(bench, &(Source.pending(Bench.agent(&1, :src)) == 0), 2_000)
      |> Bench.run(60)

    assert Bench.output(bench, :ptr) == 24 * 32 - 1024 * div(24 * 32, 1024)

    bench = Bench.update(bench, :pins, &Pins.set(&1, %{run: 0})) |> Bench.run(10)
    assert Bench.output(bench, :ptr) == 0
    bench = Bench.update(bench, :pins, &Pins.set(&1, %{run: 1}))
    bench = Bench.update(bench, :src, &Source.push(&1, [%{tdata: 0x1234, tlast: 1}]))
    bench = Bench.run(bench, 80)
    assert Core.read_mem(Bench.agent(bench, :core), @base, 32) == <<0x1234::little-256>>
    assert Core.errors(Bench.agent(bench, :core)) == []
  end

  test "interrupt latency with an ideal core is a few cycles" do
    # one period of one beat, tlast on it: from the beat to the interrupt
    core = Core.new(seed: 1, rq_ready: 1.0, irq_latency: {1, 1})

    pins =
      Pins.new(%{
        run: 1,
        base: @base,
        ring_bytes: 128,
        period_bytes: 32,
        msix_addr: 1,
        msix_data: 1
      })

    src = Source.new(:s_axis, [%{tdata: 5, tlast: 1}], valid: 1.0)
    bench = Bench.new(Tops.c2h(), core: core, pins: pins, src: src) |> Bench.run(4)
    start = bench.cycle
    bench = Bench.run_until(bench, &(Core.irq_log(Bench.agent(&1, :core)) != []), 200)
    [{irq_cycle, _}] = Core.irq_log(Bench.agent(bench, :core))
    assert irq_cycle - start < 25
  end

  @tag :verilator
  test "Verilator replays the same trace" do
    {bench, _, _, _, _} = run_case(seed: 3, beats: 40)
    assert Bench.compare_verilator(bench) == :ok
  end
end
