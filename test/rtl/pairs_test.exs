defmodule ExPcie.RTL.PairsTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias ExPcie.Regs
  alias ExPcie.Model.{Bench, Core, Driver}
  alias ExPcie.Model.Stream.{Sink, Source}
  alias ExPcie.RTL.{Dma, Endpoint}

  @vec for v <- 0..3, do: {0xFEE0_1000 + 0x1000 * v, 0x40 + v}

  # -- bench and host helpers (as in dring_endpoint_test.exs) ----------------------------------

  defp core(b), do: Bench.agent(b, :core)
  defp sink(b, name), do: Bench.agent(b, name)

  defp new_bench(opts) do
    lb = Keyword.get(opts, :loopback, false)
    parent = self()

    core =
      Core.new(
        seed: Keyword.get(opts, :seed, 1),
        mps: 128,
        mrrs: Keyword.get(opts, :mrrs, 256),
        latency: Keyword.get(opts, :latency, {4, 20}),
        rc_valid: 0.8,
        cc_ready: 0.8,
        rq_ready: 0.8,
        cq_valid: 0.8,
        irq_latency: {1, 3},
        on_irq: fn _c, {_, {:msix, _, data}} -> send(parent, {:irq, data}) end
      )

    agents =
      if lb,
        do: [core: core],
        else: [
          core: core,
          src0: Source.new(:c2h_axis, Keyword.get(opts, :beats0, []), valid: 0.8, seed: 5),
          src1: Source.new(:c2h1_axis, Keyword.get(opts, :beats1, []), valid: 0.8, seed: 7),
          sink0: Sink.new(:h2c_axis, ready: 0.8, seed: 6),
          sink1: Sink.new(:h2c1_axis, ready: 0.7, seed: 8)
        ]

    mod = Endpoint.build(pairs: 2, loopback: lb, seg_last: [1])
    {Bench.new(mod, agents) |> Bench.update(:core, &program_msix/1), mod}
  end

  defp w(c, name, v), do: Core.mmio_write(c, Regs.offset(name), v)

  defp program_msix(c) do
    for {{a, d}, i} <- Enum.with_index(@vec), reduce: c do
      c ->
        c
        |> w(:"msix#{i}_lo", a &&& 0xFFFF_FFFF)
        |> w(:"msix#{i}_hi", a >>> 32)
        |> w(:"msix#{i}_data", d)
        |> w(:"msix#{i}_ctrl", 0)
    end
  end

  defp host(b, drv, f) do
    {c, drv} = f.(core(b), drv)
    {Bench.update(b, :core, fn _ -> c end), drv}
  end

  defp settle(b), do: Bench.run_until(b, &Core.idle?(core(&1)), 20_000)

  defp read32(b, name) do
    {c, tag} = Core.mmio_read(core(b), Regs.offset(name))
    b = Bench.update(b, :core, fn _ -> c end) |> settle()
    {:ok, <<v::little-32>>, _} = Core.mmio_result(core(b), tag)
    {b, v}
  end

  defp chunks(data), do: for(<<c::binary-size(32) <- data>>, do: c)

  defp bytes(beats), do: for(beat <- beats, into: <<>>, do: <<beat.tdata::little-256>>)

  defp head_count(b, drv, ch), do: Driver.head_block(core(b), drv, ch).count

  defp drain_irqs(acc \\ []) do
    receive do
      {:irq, d} -> drain_irqs([d | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp post_all(c, d, ch, list, flags_fun) do
    list
    |> Enum.with_index()
    |> Enum.reduce({c, d}, fn {data, i}, {c, d} ->
      {c, d, _} = Driver.post_data(c, d, data, flags_fun.(i), 100 + i, ch)
      {c, d}
    end)
  end

  # -- register map and names -------------------------------------------------------------------

  test "pair p has the registers of pair 0 at 0x200 p, vector 2 p and 2 p + 1" do
    for p <- 1..3, {name, off} <- [ctrl: 0x10, status: 0x14] do
      assert Regs.offset(Regs.pair_reg(name, p)) == 0x200 * p + off
    end

    for p <- 1..3, dir <- [:h2c, :c2h], n <- ~w(base_lo base_hi ring period ptr dbase_lo dbase_hi
        dsize dhead dtail dstat wb_lo wb_hi dctrl dcount dfetch)a do
      assert Regs.offset(:"#{Regs.channel(dir, p)}_#{n}") ==
               0x200 * p + Regs.offset(:"#{dir}_#{n}")
    end

    assert Regs.offset(:h2c1_err) == 0x200 + Regs.offset(:h2c_err)
    assert Regs.offset(:c2h2_pkt) == 0x400 + Regs.offset(:c2h_pkt)
    assert Regs.split_channel(:c2h3) == {:c2h, 3}
    assert Regs.split_channel(:h2c) == {:h2c, 0}
    assert ExPcie.Host.vector(:h2c, 2) == 4
    assert ExPcie.Host.vector(:c2h, 2) == 5
  end

  test "registers of one pair do not overlap any other register or the MSI-X table" do
    for pairs <- 1..4 do
      regs = Regs.map(2 * pairs, pairs).registers
      offs = Enum.map(regs, & &1.offset)
      assert offs == Enum.uniq(offs)
      assert Enum.all?(regs, &(&1.offset < 0x4000))
    end
  end

  test "pairs: 1 keeps the map: no pairs register, no registers at 0x200" do
    one = Regs.map(4, 1)
    names = Enum.map(one.registers, & &1.name)
    refute :pairs in names
    refute :ctrl1 in names
    assert Enum.max_by(one.registers, & &1.offset).offset == 0x2000
    two = Regs.map(4, 2)
    assert (Enum.map(two.registers, & &1.name) -- names) |> Enum.any?()
    assert Enum.all?(names, &(&1 in Enum.map(two.registers, fn r -> r.name end)))
  end

  test "the map renders a C header and Markdown for several pairs" do
    h = Regs.c_header(8, 3)
    assert h =~ "H2C2_DBASE_LO_OFFSET 0x00000500u"
    md = Regs.markdown(8, 3)
    assert md =~ "`ctrl2`" and md =~ "`c2h1_dfetch`"
    assert md =~ "0x0410" and not (md =~ "0x0610")
    assert_raise ArgumentError, fn -> Regs.map(2, 2) end
    assert_raise ArgumentError, fn -> Regs.map(32, 5) end
  end

  test "the tag partition: bit 7 splits data reads and descriptor fetches, all pairs distinct" do
    # data tags: slot (3) generation (3 - k) pair (k) epoch (1); fetch tags: 1 gen (4) channel (3)
    for pairs <- 1..4 do
      k = ExHdl.RTL.Builder.ceil_log2(pairs)
      assert 3 + (3 - k) + k + 1 + 1 == 8
    end

    m = Dma.build(pairs: 4)
    assert m.name == "pcie_dma_p4"
    assert_raise ArgumentError, fn -> Dma.build(pairs: 5) end
    assert_raise ArgumentError, fn -> ExPcie.RTL.H2c.build(pairs: 2, pair: 2) end
    assert_raise ArgumentError, fn -> ExPcie.RTL.H2c.build(seg_last: true) end
  end

  test "ports: pair 0 keeps its names, pair p has the pair number in them" do
    names = fn mod -> MapSet.new(mod.ports, & &1.name) end
    one = names.(Endpoint.build())
    two = names.(Endpoint.build(pairs: 2, seg_last: [1]))
    assert MapSet.subset?(one, two)

    extra = MapSet.difference(two, one)
    assert :h2c1_axis_tdata in extra and :h2c1_axis_tlast in extra
    assert :c2h1_axis_tlast in extra
    refute :h2c_axis_tlast in two

    dma = names.(Dma.build(pairs: 2))
    assert :h2c1_run in dma and :c2h1_pkt_count in dma and :h2c1_err_count in dma
    assert MapSet.subset?(names.(Dma.build()), dma)
  end

  # -- both pairs at the same time ----------------------------------------------------------------

  @h0 [64, 224, 1024, 32, 480]
  @h1 [96, 256, 32, 800, 160, 512]
  @c1_packets [3, 5, 2, 8, 1]

  defp scenario(seed, mrrs, latency) do
    :rand.seed(:exsss, {seed, 5, 5})
    h0 = for n <- @h0, do: :rand.bytes(n)
    h1 = for n <- @h1, do: :rand.bytes(n)
    c0 = :rand.bytes(1024)
    c1 = for n <- @c1_packets, do: :rand.bytes(32 * n)

    beats0 =
      for {<<v::little-256>>, i} <- Enum.with_index(chunks(c0)),
          do: %{tdata: v, tlast: if(rem(i, 3) == 2, do: 1, else: 0)}

    beats1 =
      for p <- c1, {<<v::little-256>>, i} <- Enum.with_index(chunks(p)) do
        %{tdata: v, tlast: if(i == div(byte_size(p), 32) - 1, do: 1, else: 0)}
      end

    {b, _} = new_bench(seed: seed, mrrs: mrrs, latency: latency, beats0: beats0, beats1: beats1)
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} =
          Enum.reduce([:h2c, :c2h, :h2c1, :c2h1], {c, d}, fn ch, {c, d} ->
            {c, d} = Driver.setup(c, d, ch, entries: 8, irq: true)
            Driver.start(c, d, ch)
          end)

        {c, d} = post_all(c, d, :h2c, h0, &if(&1 in [1, 4], do: [:irq], else: []))
        {c, d} = post_all(c, d, :h2c1, h1, &if(&1 in [2, 5], do: [:irq], else: []))

        {c, d} =
          for i <- 0..3, reduce: {c, d} do
            {c, d} ->
              {c, d, _} = Driver.post_buffer(c, d, :c2h, 256, if(i == 3, do: [:irq], else: []), i)
              {c, d}
          end

        {c, d} =
          for i <- 0..5, reduce: {c, d} do
            {c, d} ->
              {c, d, _} = Driver.post_buffer(c, d, :c2h1, 512, [:stop, :irq], i)
              {c, d}
          end

        c =
          for ch <- [:h2c, :c2h, :h2c1, :c2h1], reduce: c, do: (c -> Driver.doorbell(c, d, ch))

        {c, d}
      end)

    want = [h2c: 5, c2h: 4, h2c1: 6, c2h1: 5]

    b =
      Bench.run_until(
        b,
        fn b -> Enum.all?(want, fn {ch, n} -> head_count(b, drv, ch) >= n end) end,
        80_000
      )
      |> Bench.run(200)

    {b, drv, %{h0: h0, h1: h1, c0: c0, c1: c1}}
  end

  for seed <- [1, 2, 3] do
    test "both pairs move data at once with split, reordered completions (seed #{seed})" do
      seed = unquote(seed)
      {mrrs, latency} = if seed == 3, do: {128, {4, 60}}, else: {256, {4, 20}}
      {b, drv, d} = scenario(seed, mrrs, latency)

      assert Core.errors(core(b)) == []

      # H2C pair 0: no tlast, the stream is the concatenation of the descriptors
      beats0 = Sink.beats(sink(b, :sink0))
      assert bytes(beats0) == IO.iodata_to_binary(d.h0)
      refute Enum.any?(beats0, &Map.has_key?(&1, :tlast))

      # H2C pair 1: tlast on the last beat of each descriptor segment
      beats1 = Sink.beats(sink(b, :sink1))
      assert bytes(beats1) == IO.iodata_to_binary(d.h1)
      lasts = for {beat, i} <- Enum.with_index(beats1), beat.tlast == 1, do: i

      ends =
        @h1 |> Enum.map(&div(&1, 32)) |> Enum.scan(&(&1 + &2)) |> Enum.map(&(&1 - 1))

      assert lasts == ends

      # C2H pair 0: four 256-byte buffers; pair 1: one descriptor per packet
      {c, drv, done0} = Driver.reap(core(b), drv, :c2h)
      assert IO.iodata_to_binary(Enum.map(done0, & &1.data)) == d.c0
      {_c, drv, done1} = Driver.reap(c, drv, :c2h1)
      assert Enum.map(done1, & &1.bytes) == Enum.map(d.c1, &byte_size/1)
      assert Enum.map(done1, & &1.data) == d.c1
      assert Enum.all?(done1, &(&1.eop and &1.done and not &1.error))

      {_c, _drv, done_h1} = Driver.reap(core(b), drv, :h2c1)
      assert Enum.map(done_h1, & &1.bytes) == @h1

      # every channel raised its own vector (0 H2C0, 1 C2H0, 2 H2C1, 3 C2H1)
      assert drain_irqs() |> Enum.uniq() |> Enum.sort() == [0x40, 0x41, 0x42, 0x43]

      for ch <- [:h2c, :c2h, :h2c1, :c2h1] do
        {_b, st} = read32(b, :"#{ch}_dstat")
        assert st == 0
      end

      {b, e0} = read32(b, :h2c_err)
      {_b, e1} = read32(b, :h2c1_err)
      assert {e0, e1} == {0, 0}
    end
  end

  test "interrupts per vector: only the channel whose descriptor asks raises its vector" do
    :rand.seed(:exsss, {9, 9, 9})
    {b, _} = new_bench([])
    drv = Driver.new()
    data = :rand.bytes(128)

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :h2c1, entries: 4, irq: true)
        {c, d} = Driver.setup(c, d, :h2c, entries: 4, irq: true)
        {c, d} = Driver.start(c, d, :h2c1)
        {c, d} = Driver.start(c, d, :h2c)
        {c, d, _} = Driver.post_data(c, d, data, [:irq], 0, :h2c1)
        {c, d, _} = Driver.post_data(c, d, data, [], 0, :h2c)
        {c |> Driver.doorbell(d, :h2c1) |> Driver.doorbell(d, :h2c), d}
      end)

    b =
      Bench.run_until(
        b,
        &(head_count(&1, drv, :h2c1) >= 1 and head_count(&1, drv, :h2c) >= 1),
        20_000
      )
      |> Bench.run(100)

    assert drain_irqs() |> Enum.uniq() == [0x42]
    assert Core.errors(core(b)) == []

    # a forced vector still works for the vectors above 2 * pairs - 1, and for the pair vectors
    b = Bench.update(b, :core, &w(&1, :irq_force, 0b1001)) |> settle() |> Bench.run(100)
    assert drain_irqs() |> Enum.sort() == [0x40, 0x43]
    {_b, pend} = read32(b, :irq_pending)
    assert pend == 0
  end

  test "a restart of pair 1 does not take completions of the run before, pair 0 streams on" do
    :rand.seed(:exsss, {4, 4, 4})
    old = for _ <- 1..2, do: :rand.bytes(1024)
    fresh = for n <- [512, 256, 64], do: :rand.bytes(n)
    ref0 = for _ <- 1..3, do: :rand.bytes(1024)
    {b, _} = new_bench(seed: 4, latency: {30, 80}, mrrs: 256)
    drv = Driver.new()

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.setup(c, d, :h2c1, entries: 8, wb: :head)
        {c, d} = Driver.setup(c, d, :h2c, entries: 8, wb: :head)
        {c, d} = Driver.start(c, d, :h2c)
        {c, d} = Driver.start(c, d, :h2c1)
        {c, d} = post_all(c, d, :h2c, ref0, fn _ -> [] end)
        {c, d} = post_all(c, d, :h2c1, old, fn _ -> [] end)
        {c |> Driver.doorbell(d, :h2c) |> Driver.doorbell(d, :h2c1), d}
      end)

    # let reads of pair 1 get out, then stop and start again at once
    b = Bench.run(b, 60)

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = Driver.stop(c, d, :h2c1)
        c = Driver.doorbell(c, d, :h2c1)
        Driver.start(c, d, :h2c1)
      end)

    b = settle(b)
    seen = byte_size(bytes(Sink.beats(sink(b, :sink1))))

    {b, drv} =
      host(b, drv, fn c, d ->
        {c, d} = post_all(c, d, :h2c1, fresh, fn _ -> [] end)
        {Driver.doorbell(c, d, :h2c1), d}
      end)

    want = IO.iodata_to_binary(fresh)

    b =
      Bench.run_until(
        b,
        &(byte_size(bytes(Sink.beats(sink(&1, :sink1)))) >= seen + byte_size(want) and
            head_count(&1, drv, :h2c) >= 3),
        60_000
      )
      |> Bench.run(300)

    got = bytes(Sink.beats(sink(b, :sink1)))
    assert binary_part(got, seen, byte_size(want)) == want
    assert bytes(Sink.beats(sink(b, :sink0))) == IO.iodata_to_binary(ref0)
    assert Core.errors(core(b)) == []
  end

  # -- simple rings of pair 1 --------------------------------------------------------------------

  test "pair 1 in simple ring mode: loopback, vectors 2 and 3, own status and pointers" do
    :rand.seed(:exsss, {1, 2, 3})
    ring = 2048
    h2c = 0x1_0000_0000
    c2h = 0x1_0010_0000
    data = :rand.bytes(ring)
    {b, mod} = new_bench(loopback: true)
    assert mod.name == "pcie_endpoint_4_p2sl1_loopback"
    b = Bench.update(b, :core, &Core.put_mem(&1, h2c, data))

    b =
      Bench.update(b, :core, fn c ->
        c
        |> w(:h2c1_base_lo, h2c &&& 0xFFFF_FFFF)
        |> w(:h2c1_base_hi, h2c >>> 32)
        |> w(:h2c1_ring, ring)
        |> w(:h2c1_period, 512)
        |> w(:c2h1_base_lo, c2h &&& 0xFFFF_FFFF)
        |> w(:c2h1_base_hi, c2h >>> 32)
        |> w(:c2h1_ring, ring)
        |> w(:c2h1_period, 512)
        |> w(:ctrl1, 3)
      end)

    b = Bench.run_until(b, &(length(Core.irq_log(core(&1))) >= 8), 40_000)
    assert Core.errors(core(b)) == []
    assert Core.read_mem(core(b), c2h, ring) == data
    assert drain_irqs() |> Enum.uniq() |> Enum.sort() == [0x42, 0x43]

    {b, ctrl1} = read32(b, :ctrl1)
    assert ctrl1 == 3
    {b, ctrl0} = read32(b, :ctrl)
    assert ctrl0 == 0
    {b, st1} = read32(b, :status1)
    assert (st1 &&& 3) == 3
    {b, st0} = read32(b, :status)
    assert st0 == 0
    {b, pkts} = read32(b, :c2h1_pkt)
    assert pkts > 0
    {b, p0} = read32(b, :c2h_pkt)
    assert p0 == 0
    {b, pairs} = read32(b, :pairs)
    assert pairs == 2

    b = Bench.update(b, :core, &w(&1, :ctrl1, 0)) |> settle() |> Bench.run(60)
    {b, ptr} = read32(b, :c2h1_ptr)
    assert ptr == 0
    b = Bench.update(b, :core, &w(&1, :status1, 7)) |> settle()
    {_b, st1} = read32(b, :status1)
    assert st1 == 0
  end

  # -- Verilator ------------------------------------------------------------------------------------

  @tag :verilator
  @tag timeout: 600_000
  test "Verilator replays the two-pair trace" do
    {b, _drv, _d} = scenario(1, 256, {4, 20})
    assert Bench.compare_verilator(b) == :ok
  end
end
