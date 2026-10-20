defmodule ExPcie.RTL.H2cTest do
  use ExUnit.Case, async: true

  alias ExPcie.Dma.Ref
  alias ExPcie.Model.{Bench, Core, Pins}
  alias ExPcie.Model.Stream.Sink
  alias ExPcie.Test.Tops

  @base 0x2_0000_0000

  defp run_case(opts) do
    seed = Keyword.get(opts, :seed, 1)
    ring = Keyword.get(opts, :ring, 2048)
    period = Keyword.get(opts, :period, 512)
    base = Keyword.get(opts, :base, @base)
    laps = Keyword.get(opts, :laps, 3)
    :rand.seed(:exsss, {seed, 7, 7})
    data = :rand.bytes(ring)

    core =
      Core.new(
        seed: seed,
        mps: Keyword.get(opts, :mps, 128),
        mrrs: Keyword.get(opts, :mrrs, 512),
        rcb: Keyword.get(opts, :rcb, 64),
        cuts: Keyword.get(opts, :cuts, :random),
        reorder: Keyword.get(opts, :reorder, true),
        latency: Keyword.get(opts, :latency, {4, 30}),
        rc_valid: Keyword.get(opts, :rc_valid, 0.8),
        rq_ready: Keyword.get(opts, :rq_ready, 0.8),
        error_reads: Keyword.get(opts, :error_reads, []),
        irq_latency: {1, 2}
      )
      |> Core.put_mem(base, data)

    pins =
      Pins.new(%{
        run: 1,
        base: base,
        ring_bytes: ring,
        period_bytes: period,
        msix_addr: 0xFEE0_0000,
        msix_data: 0x77
      })

    bench =
      Bench.new(Tops.h2c(),
        core: core,
        pins: pins,
        sink: Sink.new(:m_axis, ready: Keyword.get(opts, :ready, 0.7), seed: seed)
      )

    want_beats = div(ring * laps, 32)

    bench =
      Bench.run_until(bench, &(length(Sink.beats(Bench.agent(&1, :sink))) >= want_beats), 60_000)

    {bench, data, want_beats}
  end

  defp stream_bytes(bench),
    do: for(b <- Sink.beats(Bench.agent(bench, :sink)), into: <<>>, do: <<b.tdata::little-256>>)

  test "streams the ring in a loop, with split and reordered completions" do
    {bench, data, n} = run_case(seed: 1)
    got = stream_bytes(bench)
    want = :binary.copy(data, 3)
    assert binary_part(got, 0, n * 32) == binary_part(want, 0, n * 32)
    core = Bench.agent(bench, :core)
    assert Core.errors(core) == []
    assert Bench.output(bench, :err_count) == 0

    assert requests(core) ==
             Ref.h2c_requests(length(requests(core)), base: @base, ring: 2048, mrrs: 512)

    assert length(requests(core)) > 8
  end

  defp requests(core),
    do: for(%{kind: :mrd} = t <- Core.rq_log(core), do: {t.address, t.length_dw * 4})

  test "random configurations against the reference" do
    for seed <- 20..27 do
      :rand.seed(:exsss, {seed, 9, 9})
      period = Enum.random([64, 128, 256, 512])
      ring = period * Enum.random([2, 4])
      mrrs = Enum.random([128, 256, 512])
      base = 0x5_0000_0000 + 32 * :rand.uniform(200)
      rcb = Enum.random([64, 128])

      {bench, data, n} =
        run_case(
          seed: seed,
          ring: ring,
          period: period,
          mrrs: mrrs,
          rcb: rcb,
          mps: Enum.random([128, 256]),
          base: base,
          cuts: Enum.random([:random, :all, :none]),
          reorder: Enum.random([true, false]),
          ready: Enum.random([0.3, 1.0]),
          rc_valid: Enum.random([0.5, 1.0]),
          latency: Enum.random([{2, 4}, {5, 60}]),
          laps: 4
        )

      core = Bench.agent(bench, :core)
      assert Core.errors(core) == [], "seed #{seed}"
      got = stream_bytes(bench)
      assert binary_part(got, 0, n * 32) == Ref.h2c_stream(data, n * 32), "seed #{seed}"
      reqs = requests(core)

      assert reqs == Ref.h2c_requests(length(reqs), base: base, ring: ring, mrrs: mrrs),
             "seed #{seed}"
    end
  end

  test "restart: clearing run restarts the ring from its start" do
    {bench, data, _} = run_case(seed: 6, laps: 1)
    bench = Bench.update(bench, :pins, &Pins.set(&1, %{run: 0})) |> Bench.run(10)
    n_before = length(Sink.beats(Bench.agent(bench, :sink)))
    assert Bench.output(bench, :ptr) == 0
    bench = Bench.update(bench, :pins, &Pins.set(&1, %{run: 1}))

    bench =
      Bench.run_until(bench, &(length(Sink.beats(Bench.agent(&1, :sink))) >= n_before + 8), 5_000)

    beats = Sink.beats(Bench.agent(bench, :sink)) |> Enum.drop(n_before) |> Enum.take(8)
    assert Ref.stream_bytes(Enum.map(beats, & &1.tdata)) == binary_part(data, 0, 256)
    assert Bench.output(bench, :err_count) == 0
  end

  test "interrupt per period, no completion splitting, in-order" do
    {bench, _data, _} =
      run_case(
        seed: 2,
        cuts: :none,
        reorder: false,
        mps: 256,
        mrrs: 256,
        ready: 1.0,
        rc_valid: 1.0,
        rq_ready: 1.0,
        period: 256
      )

    core = Bench.agent(bench, :core)
    assert Core.errors(core) == []
    delivered = length(Sink.beats(Bench.agent(bench, :sink))) * 32
    irqs = length(Core.irq_log(core))
    assert irqs in [div(delivered, 256) - 1, div(delivered, 256)]
  end

  test "RCB 128 and 4 KiB boundaries, small MRRS" do
    {bench, data, n} =
      run_case(
        seed: 3,
        base: 0x3_0000_0000 + 4096 - 480,
        ring: 1024,
        period: 256,
        mrrs: 128,
        rcb: 128,
        mps: 256,
        laps: 4
      )

    got = stream_bytes(bench)
    assert binary_part(got, 0, n * 32) == binary_part(:binary.copy(data, 4), 0, n * 32)
    assert Core.errors(Bench.agent(bench, :core)) == []
  end

  test "an unsupported request completion is counted and does not stall" do
    {bench, _data, _n} = run_case(seed: 4, error_reads: [@base + 256], laps: 2)
    assert Bench.output(bench, :err_count) >= 1
    assert Core.errors(Bench.agent(bench, :core)) == []
  end

  @tag :verilator
  test "Verilator replays the same trace" do
    {bench, _, _} = run_case(seed: 5, laps: 1)
    assert Bench.compare_verilator(bench) == :ok
  end
end
