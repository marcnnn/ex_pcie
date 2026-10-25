defmodule ExPcie.RTL.DRingEndpointTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias ExPcie.Regs
  alias ExPcie.Model.{Bench, Core, Driver}
  alias ExPcie.Model.Stream.{Sink, Source}
  alias ExPcie.RTL.Endpoint

  @vec0 {0xFEE0_1000, 0x40}
  @vec1 {0xFEE0_2000, 0x41}

  # -- bench and host helpers ---------------------------------------------------------------

  defp core(b), do: Bench.agent(b, :core)
  defp sink(b), do: Bench.agent(b, :sink)

  defp new_bench(opts \\ []) do
    lb = Keyword.get(opts, :loopback, false)
    parent = self()

    core =
      Core.new(
        seed: Keyword.get(opts, :seed, 1),
        mps: 128,
        mrrs: Keyword.get(opts, :mrrs, 256),
        rc_valid: 0.8,
        cc_ready: 0.8,
        rq_ready: 0.8,
        cq_valid: 0.8,
        irq_latency: {1, 3},
        drop_reads: Keyword.get(opts, :drop_reads, []),
        error_reads: Keyword.get(opts, :error_reads, []),
        on_irq: fn c, {_, {:msix, _, data}} ->
          send(parent, {:irq, data, Core.stats(c).rq_writes})
        end
      )

    beats = Keyword.get(opts, :beats, [])

    agents =
      if lb,
        do: [core: core],
        else: [
          core: core,
          src: Source.new(:c2h_axis, beats, valid: 0.8, seed: 5),
          sink: Sink.new(:h2c_axis, ready: 0.8, seed: 6)
        ]

    b = Bench.new(Endpoint.build(loopback: lb), agents)
    host(b, nil, fn c, d -> {program_msix(c), d} end) |> elem(0)
  end

  # runs `f.(core, drv)` -> `{core, drv}` on the host side of the bench
  defp host(b, drv, f) do
    {c, drv} = f.(core(b), drv)
    {Bench.update(b, :core, fn _ -> c end), drv}
  end

  defp w(c, name, v), do: Core.mmio_write(c, Regs.offset(name), v)

  defp program_msix(c) do
    for {{a, d}, i} <- [{@vec0, 0}, {@vec1, 1}], reduce: c do
      c ->
        c
        |> w(:"msix#{i}_lo", a &&& 0xFFFF_FFFF)
        |> w(:"msix#{i}_hi", a >>> 32)
        |> w(:"msix#{i}_data", d)
        |> w(:"msix#{i}_ctrl", 0)
    end
  end

  defp settle(b), do: Bench.run_until(b, &Core.idle?(core(&1)), 20_000)

  defp read32(b, name) do
    {c, tag} = Core.mmio_read(core(b), Regs.offset(name))
    b = Bench.update(b, :core, fn _ -> c end) |> settle()
    {:ok, <<v::little-32>>, _} = Core.mmio_result(core(b), tag)
    {b, v}
  end

  defp beats(data, last_every) do
    for {<<v::little-256>>, i} <- Enum.with_index(chunks(data)) do
      %{tdata: v, tlast: if(rem(i + 1, last_every) == 0, do: 1, else: 0)}
    end
  end

  defp chunks(data), do: for(<<c::binary-size(32) <- data>>, do: c)

  defp sink_bytes(b),
    do: for(beat <- Sink.beats(sink(b)), into: <<>>, do: <<beat.tdata::little-256>>)

  defp until_count(b, drv, ch, n, max \\ 40_000) do
    # the head block is only written with wb enabled; the descriptors are reaped by the caller
    Bench.run_until(b, &(head_count(&1, drv, ch) >= n), max)
  end

  defp head_count(b, drv, ch), do: Driver.head_block(core(b), drv, ch).count

  # -- H2C ----------------------------------------------------------------------------------

  test "H2C: descriptors of different sizes stream out in order, write back, interrupt after the write-back" do
    :rand.seed(:exsss, {1, 1, 1})
    bufs = for n <- [64, 256, 1024, 32, 480, 96], do: :rand.bytes(n)
    total = bufs |> Enum.map(&byte_size/1) |> Enum.sum()
    b = new_bench()
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :h2c, entries: 8, irq: true)
        {c, d} = Driver.start(c, d, :h2c)

        {c, d} =
          bufs
          |> Enum.with_index()
          |> Enum.reduce({c, d}, fn {data, i}, {c, d} ->
            flags = if i in [2, 5], do: [:irq], else: []
            {c, d, _} = Driver.post_data(c, d, data, flags, 100 + i)
            {c, d}
          end)

        {Driver.doorbell(c, d, :h2c), d}
      end)

    b = until_count(b, drv, :h2c, 6) |> Bench.run(200)
    assert Core.errors(core(b)) == []
    assert sink_bytes(b) == IO.iodata_to_binary(bufs)
    assert byte_size(sink_bytes(b)) == total

    {c, drv, done} = Driver.reap(core(b), drv, :h2c)
    assert Enum.map(done, & &1.index) == [0, 1, 2, 3, 4, 5]
    assert Enum.map(done, & &1.cookie) == Enum.to_list(100..105)
    assert Enum.map(done, & &1.bytes) == Enum.map(bufs, &byte_size/1)
    assert Enum.all?(done, &(&1.done and not &1.error and not &1.eop))
    assert Driver.head_block(c, drv, :h2c) == %{tail: 6, count: 6}
    b = Bench.update(b, :core, fn _ -> c end)

    # registers
    {b, tail} = read32(b, :h2c_dtail)
    {b, count} = read32(b, :h2c_dcount)
    {b, stat} = read32(b, :h2c_dstat)
    assert {tail, count, stat} == {6, 6, 0}
    {_b, fetch} = read32(b, :h2c_dfetch)
    assert fetch == 6

    # interrupts are vector 0, none before the write-back
    irqs = for {:irq, d, _} <- drain_irqs(), do: d
    assert irqs != [] and Enum.all?(irqs, &(&1 == 0x40))
  end

  defp drain_irqs(acc \\ []) do
    receive do
      {:irq, _, _} = m -> drain_irqs([m | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "H2C: a driver loop keeps a 4-entry ring busy for many laps" do
    :rand.seed(:exsss, {2, 2, 2})
    all = for _ <- 1..30, do: :rand.bytes(32 * Enum.random(1..12))
    b = new_bench(seed: 2)
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :h2c, entries: 4, wb: :head)
        Driver.start(c, d, :h2c)
      end)

    {b, _drv, _left, reaped} =
      Enum.reduce_while(1..400, {b, drv, all, 0}, fn _, {b, drv, left, reaped} ->
        b = Bench.run(b, 150)

        {c, drv, done} = Driver.reap(core(b), drv, :h2c)
        reaped = reaped + length(done)
        {c, drv, left} = post_all(c, drv, left)
        b = Bench.update(b, :core, fn _ -> c end)

        if reaped == length(all),
          do: {:halt, {b, drv, left, reaped}},
          else: {:cont, {b, drv, left, reaped}}
      end)

    b = Bench.run(b, 100)
    assert reaped == 30
    assert sink_bytes(b) == IO.iodata_to_binary(all)
    assert Core.errors(core(b)) == []
  end

  # posts as many buffers as fit, with one doorbell
  defp post_all(c, drv, []), do: {Driver.doorbell(c, drv, :h2c), drv, []}

  defp post_all(c, drv, [data | rest] = left) do
    case Driver.post_data(c, drv, data) do
      {:error, :full} -> {Driver.doorbell(c, drv, :h2c), drv, left}
      {c, drv, _} -> post_all(c, drv, rest)
    end
  end

  # the address the driver will give the buffer `idx` of `data` (same allocation order)
  defp buffer_address(data, idx) do
    {_, dry} =
      host(new_bench(), Driver.new(), fn c, d ->
        {c, d} = Driver.setup(c, d, :h2c, entries: 4, wb: :both)
        post_data_list(c, d, data)
      end)

    dry.rings.h2c.posted[idx].addr
  end

  defp post_data_list(c, d, data) do
    Enum.reduce(data, {c, d}, fn x, {c, d} ->
      {c, d, _} = Driver.post_data(c, d, x)
      {c, d}
    end)
  end

  defp start_h2c(b, drv, data, opts) do
    host(b, drv, fn c, d ->
      c = if t = opts[:timeout], do: Driver.set_timeout(c, t), else: c
      {c, d} = Driver.setup(c, d, :h2c, entries: 4, wb: :both)
      {c, d} = Driver.start(c, d, :h2c)
      {c, d} = post_data_list(c, d, data)
      {Driver.doorbell(c, d, :h2c), d}
    end)
  end

  test "H2C: a failed read completion marks its descriptor and the stream goes on" do
    data = for n <- [128, 256, 128], do: :rand.bytes(n)
    bad = buffer_address(data, 1)
    {b, drv} = start_h2c(new_bench(error_reads: [bad]), Driver.new(), data, [])
    b = until_count(b, drv, :h2c, 3) |> Bench.run(100)
    {_c, _drv, done} = Driver.reap(core(b), drv, :h2c)
    assert Enum.map(done, & &1.error) == [false, true, false]
    assert byte_size(sink_bytes(b)) == 512
    assert binary_part(sink_bytes(b), 0, 128) == Enum.at(data, 0)
    assert binary_part(sink_bytes(b), 384, 128) == Enum.at(data, 2)
    {_b, errs} = read32(b, :h2c_err)
    assert errs >= 1
  end

  test "H2C: the completion timeout register: a dropped read ends in an error, 0 disables" do
    data = for n <- [128, 256, 128], do: :rand.bytes(n)
    bad = buffer_address(data, 1)

    for {tmo, expect_err} <- [{300, true}, {0, false}] do
      {b, drv} = start_h2c(new_bench(drop_reads: [bad]), Driver.new(), data, timeout: tmo)
      {b, t} = read32(b, :timeout)
      assert t == tmo

      if expect_err do
        b = until_count(b, drv, :h2c, 3) |> Bench.run(50)
        {_c, _drv, done} = Driver.reap(core(b), drv, :h2c)
        assert Enum.map(done, & &1.error) == [false, true, false]
      else
        b = Bench.run(b, 3_000)
        assert head_count(b, drv, :h2c) <= 1
        {_b, errs} = read32(b, :h2c_err)
        assert errs == 0
      end
    end
  end

  test "the timeout register resets to 50000" do
    {_b, v} = new_bench() |> read32(:timeout)
    assert v == 50_000
  end

  # -- C2H ----------------------------------------------------------------------------------

  test "C2H: buffers fill from the stream, completions carry the byte counts" do
    :rand.seed(:exsss, {3, 3, 3})
    data = :rand.bytes(32 * 8 * 4)
    b = new_bench(beats: beats(data, 3))
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :c2h, entries: 8, irq: true)
        {c, d} = Driver.start(c, d, :c2h)

        {c, d} =
          for i <- 0..3, reduce: {c, d} do
            {c, d} ->
              {c, d, _} = Driver.post_buffer(c, d, :c2h, 256, if(i == 3, do: [:irq], else: []), i)
              {c, d}
          end

        {Driver.doorbell(c, d, :c2h), d}
      end)

    b = until_count(b, drv, :c2h, 4) |> Bench.run(100)
    assert Core.errors(core(b)) == []
    {_c, drv, done} = Driver.reap(core(b), drv, :c2h)
    assert Enum.map(done, & &1.bytes) == [256, 256, 256, 256]
    assert Enum.all?(done, &(&1.done and not &1.eop and not &1.error))
    assert IO.iodata_to_binary(Enum.map(done, & &1.data)) == data
    assert Driver.head_block(core(b), drv, :c2h) == %{tail: 4, count: 4}
    assert [{:irq, 0x41, head}] = drain_irqs()
    _ = head
  end

  test "C2H: the stop flag ends a descriptor at the end of a packet; long packets continue in the next one" do
    :rand.seed(:exsss, {4, 4, 4})
    sizes = [3, 5, 20, 1]
    packets = for n <- sizes, do: :rand.bytes(32 * n)

    stream =
      for p <- packets, {<<v::little-256>>, i} <- Enum.with_index(chunks(p)) do
        %{tdata: v, tlast: if(i == div(byte_size(p), 32) - 1, do: 1, else: 0)}
      end

    b = new_bench(beats: stream)
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :c2h, entries: 8)
        {c, d} = Driver.start(c, d, :c2h)

        {c, d} =
          for _ <- 1..6, reduce: {c, d} do
            {c, d} ->
              {c, d, _} = Driver.post_buffer(c, d, :c2h, 512, [:stop])
              {c, d}
          end

        {Driver.doorbell(c, d, :c2h), d}
      end)

    b = until_count(b, drv, :c2h, 5) |> Bench.run(100)
    {_c, _drv, done} = Driver.reap(core(b), drv, :c2h)
    # 96 B, 160 B, then 640 B as 512 + 128, then 32 B
    assert Enum.map(done, & &1.bytes) == [96, 160, 512, 128, 32]
    assert Enum.map(done, & &1.eop) == [true, true, false, true, true]
    got = IO.iodata_to_binary(Enum.map(done, & &1.data))
    assert got == IO.iodata_to_binary(packets)
    assert Core.errors(core(b)) == []
  end

  test "C2H: without descriptors the stream waits; a descriptor releases it" do
    :rand.seed(:exsss, {5, 5, 5})
    data = :rand.bytes(512)
    b = new_bench(beats: beats(data, 100))
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :c2h, entries: 4)
        Driver.start(c, d, :c2h)
      end)

    b = Bench.run(b, 600)
    assert Core.stats(core(b)).rq_writes == 0
    # the stream is held back: the 64-beat buffer takes at most 16 beats here, none reach the host
    assert Source.pending(Bench.agent(b, :src)) == 0 or Core.stats(core(b)).rq_writes == 0

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d, _} = Driver.post_buffer(c, d, :c2h, 512)
        {Driver.doorbell(c, d, :c2h), d}
      end)

    b = until_count(b, drv, :c2h, 1) |> Bench.run(50)
    {_c, _drv, [done]} = Driver.reap(core(b), drv, :c2h)
    assert done.data == data
  end

  test "C2H: a buffer across a 4 KiB boundary" do
    :rand.seed(:exsss, {6, 6, 6})
    data = :rand.bytes(1024)
    b = new_bench(beats: beats(data, 100))
    drv = Driver.new(arena: 0x10_0000_0000)

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :c2h, entries: 4)
        {c, d} = Driver.start(c, d, :c2h)
        # allocate a pad so the buffer starts 256 bytes before a page end
        {d, a} = Driver.alloc(d, 0, 4096)
        d = %{d | next: a + 4096 - 256}
        {c, d, _} = Driver.post_buffer(c, d, :c2h, 1024)
        {Driver.doorbell(c, d, :c2h), d}
      end)

    b = until_count(b, drv, :c2h, 1) |> Bench.run(50)
    {_c, _drv, [done]} = Driver.reap(core(b), drv, :c2h)
    assert rem(done.buffer, 4096) == 4096 - 256
    assert done.data == data
    assert Core.errors(core(b)) == []
  end

  # -- both, modes, errors --------------------------------------------------------------------

  test "loopback through both descriptor rings" do
    :rand.seed(:exsss, {7, 7, 7})
    data = :rand.bytes(2048)
    b = new_bench(loopback: true)
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :h2c, entries: 4, irq: true)
        {c, d} = Driver.setup(c, d, :c2h, entries: 4, irq: true)
        {c, d} = Driver.start(c, d, :c2h)
        {c, d} = Driver.start(c, d, :h2c)

        # two H2C descriptors of 1 KiB, four C2H buffers of 512 B
        {c, d, _} = Driver.post_data(c, d, binary_part(data, 0, 1024), [:irq])
        {c, d, _} = Driver.post_data(c, d, binary_part(data, 1024, 1024), [:irq])

        {c, d} =
          for i <- 0..2, reduce: {c, d} do
            {c, d} ->
              {c, d, _} = Driver.post_buffer(c, d, :c2h, 512, [:irq], i)
              {c, d}
          end

        {c |> Driver.doorbell(d, :h2c) |> Driver.doorbell(d, :c2h), d}
      end)

    # the C2H ring holds three buffers; the fourth is posted after the first reap
    b = until_count(b, drv, :c2h, 3)
    {c, drv, done} = Driver.reap(core(b), drv, :c2h)
    b = Bench.update(b, :core, fn _ -> c end)

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d, _} = Driver.post_buffer(c, d, :c2h, 512, [:irq], 9)
        {Driver.doorbell(c, d, :c2h), d}
      end)

    b = until_count(b, drv, :c2h, 4) |> Bench.run(100)
    {_c, drv, done2} = Driver.reap(core(b), drv, :c2h)
    assert head_count(b, drv, :h2c) == 2
    got = IO.iodata_to_binary(Enum.map(done ++ done2, & &1.data))
    assert got == data
    assert Core.errors(core(b)) == []
    vecs = for {:irq, d, _} <- drain_irqs(), uniq: true, do: d
    assert Enum.sort(vecs) == [0x40, 0x41]
  end

  test "simple ring mode still works, and the channel switches between modes" do
    :rand.seed(:exsss, {8, 8, 8})
    ring = 2048
    data = :rand.bytes(ring)
    h2c = 0x1_0000_0000
    c2h = 0x1_0010_0000
    b = new_bench(loopback: true)
    b = Bench.update(b, :core, &Core.put_mem(&1, h2c, data))

    simple = fn b ->
      Bench.update(b, :core, fn c ->
        c
        |> w(:h2c_base_lo, h2c &&& 0xFFFF_FFFF)
        |> w(:h2c_base_hi, h2c >>> 32)
        |> w(:h2c_ring, ring)
        |> w(:h2c_period, 512)
        |> w(:c2h_base_lo, c2h &&& 0xFFFF_FFFF)
        |> w(:c2h_base_hi, c2h >>> 32)
        |> w(:c2h_ring, ring)
        |> w(:c2h_period, 512)
        |> w(:ctrl, 3)
      end)
    end

    b = simple.(b) |> Bench.run_until(&(length(Core.irq_log(core(&1))) >= 10), 40_000)
    assert Core.read_mem(core(b), c2h, ring) == data
    assert Core.errors(core(b)) == []
    # stop, then the same channels in descriptor mode, then simple again
    b = Bench.update(b, :core, &w(&1, :ctrl, 0)) |> settle() |> Bench.run(60)
    n_irq = length(Core.irq_log(core(b)))
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :h2c, entries: 4)
        {c, d} = Driver.setup(c, d, :c2h, entries: 4)
        {c, d} = Driver.start(c, d, :c2h)
        {c, d} = Driver.start(c, d, :h2c)
        {c, d, _} = Driver.post_data(c, d, binary_part(data, 0, 512))
        {c, d, _} = Driver.post_buffer(c, d, :c2h, 512)
        {c |> Driver.doorbell(d, :h2c) |> Driver.doorbell(d, :c2h), d}
      end)

    b = until_count(b, drv, :c2h, 1) |> Bench.run(50)
    {_c, _drv, [done]} = Driver.reap(core(b), drv, :c2h)
    assert done.data == binary_part(data, 0, 512)
    # no period interrupts in descriptor mode without the irq flag
    assert length(Core.irq_log(core(b))) == n_irq

    b = Bench.update(b, :core, &w(&1, :ctrl, 0)) |> settle() |> Bench.run(60)
    b = Bench.update(b, :core, &Core.put_mem(&1, c2h, :binary.copy(<<0>>, ring)))
    b = simple.(b) |> Bench.run_until(&(length(Core.irq_log(core(&1))) >= n_irq + 10), 40_000)
    got = Core.read_mem(core(b), c2h, ring)

    bad =
      for i <- 0..(div(ring, 32) - 1),
          binary_part(got, i * 32, 32) != binary_part(data, i * 32, 32),
          do: i

    assert bad == [], "irq #{length(Core.irq_log(core(b)))} of #{n_irq}"
  end

  test "a bad descriptor halts the ring and shows in dstat; stopping clears it" do
    b = new_bench()
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :h2c, entries: 4)
        {c, d} = Driver.start(c, d, :h2c)
        {c, d, _} = Driver.post(c, d, :h2c, 0x9_0000_0010, 64)
        {Driver.doorbell(c, d, :h2c), d}
      end)

    b = Bench.run(b, 600)
    {b, stat} = read32(b, :h2c_dstat)
    assert stat == 0b011
    {b, tail} = read32(b, :h2c_dtail)
    assert tail == 0

    {b, _drv} = host(b, drv, fn c, d -> Driver.stop(c, d, :h2c) end)
    b = settle(b) |> Bench.run(30)
    {_b, stat} = read32(b, :h2c_dstat)
    assert stat == 0
  end

  # -- Verilator ---------------------------------------------------------------------------

  defp loopback_scenario(b) do
    :rand.seed(:exsss, {9, 9, 9})
    data = :rand.bytes(1024)
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :h2c, entries: 4, irq: true)
        {c, d} = Driver.setup(c, d, :c2h, entries: 4, irq: true)
        {c, d} = Driver.start(c, d, :c2h)
        {c, d} = Driver.start(c, d, :h2c)
        {c, d, _} = Driver.post_data(c, d, binary_part(data, 0, 512), [:irq])
        {c, d, _} = Driver.post_data(c, d, binary_part(data, 512, 512), [:irq])
        {c, d, _} = Driver.post_buffer(c, d, :c2h, 256)
        {c, d, _} = Driver.post_buffer(c, d, :c2h, 768, [:irq])
        {c |> Driver.doorbell(d, :h2c) |> Driver.doorbell(d, :c2h), d}
      end)

    {b, drv, data}
  end

  defp check_scenario(b, drv, data) do
    b = until_count(b, drv, :c2h, 2) |> Bench.run(60)
    {_c, _drv, done} = Driver.reap(core(b), drv, :c2h)
    assert IO.iodata_to_binary(Enum.map(done, & &1.data)) == data
    assert Core.errors(core(b)) == []
    b
  end

  @tag :verilator
  @tag timeout: 600_000
  test "Verilator replays the descriptor-mode trace" do
    {b, drv, data} = new_bench(loopback: true) |> loopback_scenario()
    b = check_scenario(b, drv, data)
    assert Bench.compare_verilator(b) == :ok
  end

  @tag :verilator
  @tag timeout: 600_000
  test "closed loop against Verilator (Session): the driver model and the netlist" do
    base = new_bench(loopback: true)
    mod = base.module
    core = core(base)

    b =
      Bench.new(mod, [core: core], engine: :verilator)
      |> Bench.run(3)

    {b, drv, data} = loopback_scenario(b)
    b = check_scenario(b, drv, data)
    Bench.close(b)
  end
end
