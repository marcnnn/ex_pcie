defmodule ExPcie.RTL.Bar0BridgeTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias ExPcie.Model.{Bench, Core}
  alias ExPcie.Test.Tops
  alias ExPcie.{Axis, Desc, TLP}

  defp bench(opts \\ []) do
    Bench.new(Tops.bridge_regs(), [core: Core.new(opts)], idle: %{ro_a: 0xA5A5_0001})
  end

  defp host(b, f), do: Bench.update(b, :core, f)
  defp core(b), do: Bench.agent(b, :core)

  defp settle(b),
    do: b |> Bench.run_until(&Core.idle?(core(&1)), 3000) |> Bench.run(20)

  defp read(b, off, n \\ 1, opts \\ []) do
    {c, tag} = Core.mmio_read(core(b), off, n, opts)
    b = settle(Bench.update(b, :core, fn _ -> c end))
    {b, Core.mmio_result(core(b), tag)}
  end

  test "write then read back through the bridge" do
    b = bench()
    b = host(b, &Core.mmio_write(&1, 0x08, 0xDEAD_BEEF)) |> settle()
    assert Bench.output(b, :s2) == 0xDEAD_BEEF
    {b, {:ok, <<0xDEADBEEF::little-32>>, cpl}} = read(b, 0x08)
    assert cpl.byte_count == 4 and cpl.lower_address == 8
    {b, {:ok, <<0xA5A50001::little-32>>, _}} = read(b, 0x20)
    assert Core.errors(core(b)) == []
  end

  test "multi-DWord writes and reads, byte enables" do
    b = bench()
    data = for i <- 1..4, into: <<>>, do: <<i * 0x1111_1111::little-32>>
    b = host(b, &Core.mmio_write(&1, 0x00, data)) |> settle()

    assert for(i <- 0..3, do: Bench.output(b, :"s#{i}")) == [
             0x1111_1111,
             0x2222_2222,
             0x3333_3333,
             0x4444_4444
           ]

    {b, {:ok, ^data, cpl}} = read(b, 0x00, 4)
    assert {cpl.byte_count, cpl.lower_address} == {16, 0}

    # first_be 0b0100 on a single DW: only byte 2
    b = host(b, &Core.mmio_write(&1, 0x04, 0xFFFF_FFFF, first_be: 0b0100)) |> settle()
    assert Bench.output(b, :s1) == 0x22FF_2222

    # partial first and last byte enables over 3 DW
    b =
      host(
        b,
        &Core.mmio_write(
          &1,
          0x00,
          <<0xAAAAAAAA::32, 0xBBBBBBBB::32, 0xCCCCCCCC::32>>
          |> then(fn x -> for <<w::32 <- x>>, into: <<>>, do: <<w::little-32>> end),
          first_be: 0b1100,
          last_be: 0b0011
        )
      )
      |> settle()

    assert Bench.output(b, :s0) == 0xAAAA_1111
    assert Bench.output(b, :s1) == 0xBBBBBBBB
    assert Bench.output(b, :s2) == 0x3333_CCCC

    {b, {:ok, _, cpl}} = read(b, 0x00, 3, first_be: 0b1100, last_be: 0b0011)
    assert cpl.byte_count == 12 - 2 - 2
    assert cpl.lower_address == 2
    {_b, {:ok, _, cpl}} = read(b, 0x04, 1, first_be: 0b0110)
    assert cpl.byte_count == 2 and cpl.lower_address == (4 ||| 1)
  end

  test "unsupported requests get UR, posted ones are dropped" do
    b = bench()
    # other BAR read
    {c, t1} = Core.mmio_read(core(b), 0, 1, bar_id: 2)
    # 5 DW read
    {c, t2} = Core.mmio_read(c, 0, 5)
    # poisoned read
    tlp = %TLP{kind: :mrd, address: 0, length_dw: 1, tag: 77, ep: true, requester_id: 0x10}
    c = Core.cq_beats(%{c | mmio: Map.put(c.mmio, 77, :pending)}, Axis.cq_beats(tlp), true)
    # IO read via a hand-made descriptor
    io =
      Desc.encode(:cq, %{
        address: 0x10,
        dw_count: 1,
        req_type: :io_read,
        tag: 78,
        requester_id: 0x10
      })

    c =
      Core.cq_beats(
        %{c | mmio: Map.put(c.mmio, 78, :pending)},
        Axis.pack(:cq, io, <<>>, %{first_be: 15}),
        true
      )

    # posted: write to BAR 1, 5 DW write, message
    c = Core.mmio_write(c, 0, <<1::32>>, bar_id: 1)
    c = Core.mmio_write(c, 0, <<1::32, 2::32, 3::32, 4::32, 5::32>>)
    msg = Desc.encode(:cq, %{address: 0, dw_count: 0, req_type: :msg})
    c = Core.cq_beats(c, Axis.pack(:cq, msg, <<>>, %{}), false)
    # then a normal write and read still work
    c = Core.mmio_write(c, 0x0C, 0x1234)
    {c, t3} = Core.mmio_read(c, 0x0C)
    b = settle(Bench.update(b, :core, fn _ -> c end))

    for t <- [t1, t2, 77, 78],
        do: assert({:error, 1, %{kind: :cpl, byte_count: 4}} = Core.mmio_result(core(b), t))

    assert {:ok, <<0x1234::little-32>>, _} = Core.mmio_result(core(b), t3)
    assert Bench.output(b, :ur_count) == 4
    assert Bench.output(b, :drop_count) == 3
    assert Bench.output(b, :s0) == 0
    assert Core.errors(core(b)) == []
  end

  test "AXI errors: read becomes Completer Abort, write is counted" do
    b = bench()
    {b, {:error, 4, _}} = read(b, 0x80)
    assert Bench.output(b, :axil_err_count) == 1
    b = host(b, &Core.mmio_write(&1, 0x84, 1)) |> settle()
    assert Bench.output(b, :axil_err_count) == 2
    {_, {:ok, _, _}} = read(b, 0)
  end

  test "pulse and w1c registers via MMIO, np credits stay bounded" do
    b = bench()
    b = host(b, &Core.mmio_write(&1, 0x28, 0b1010))
    b = Bench.run_until(b, &(Bench.output(&1, :kick) != 0), 200)
    assert Bench.output(b, :kick) == 0b1010
    b = Bench.run(b, 3)
    assert Bench.output(b, :kick) == 0
    assert Core.stats(core(b)) |> is_map()
    assert core(b).np_credits <= 4
  end

  property_like = fn -> :ok end
  _ = property_like

  test "random mixed traffic against a register model with random stalls" do
    for seed <- 1..3 do
      :rand.seed(:exsss, {seed, 5, 6})

      b =
        bench(seed: seed, cq_valid: 0.7, cc_ready: 0.6)

      {c, model, expect} =
        Enum.reduce(1..60, {core(b), %{}, []}, fn _, {c, model, expect} ->
          reg = :rand.uniform(8) - 1

          case :rand.uniform(3) do
            1 ->
              v = :rand.uniform(1 <<< 32) - 1
              {Core.mmio_write(c, 4 * reg, v), Map.put(model, reg, v), expect}

            2 ->
              n = :rand.uniform(min(4, 8 - reg))
              {c, tag} = Core.mmio_read(c, 4 * reg, n)

              want =
                for i <- reg..(reg + n - 1), into: <<>>, do: <<Map.get(model, i, 0)::little-32>>

              {c, model, [{tag, want} | expect]}

            3 ->
              n = :rand.uniform(min(4, 8 - reg))
              ws = for _ <- 1..n, do: :rand.uniform(1 <<< 32) - 1

              model =
                ws
                |> Enum.with_index(reg)
                |> Enum.reduce(model, fn {w, i}, m -> Map.put(m, i, w) end)

              {Core.mmio_write(c, 4 * reg, for(w <- ws, into: <<>>, do: <<w::little-32>>)), model,
               expect}
          end
        end)

      b = settle(Bench.update(b, :core, fn _ -> c end))

      for {tag, want} <- expect, do: assert({:ok, ^want, _} = Core.mmio_result(core(b), tag))
      for {i, v} <- model, do: assert(Bench.output(b, :"s#{i}") == v)
      assert Core.errors(core(b)) == []
      if seed == 1, do: send(self(), {:bench, b})
    end

    assert_received {:bench, b}
    assert_received_trace(b)
  end

  defp assert_received_trace(b), do: assert(length(Bench.stimulus(b)) > 100)

  @tag :verilator
  test "Verilator agrees with the BEAM simulation on a random trace" do
    b = bench(seed: 9, cq_valid: 0.8, cc_ready: 0.7)
    b = host(b, &Core.mmio_write(&1, 0x00, 0x11))
    {c, _} = Core.mmio_read(core(b), 0x00)
    c = Core.mmio_write(c, 4, <<1::little-32, 2::little-32>>)
    {c, _} = Core.mmio_read(c, 0x80)
    {c, _} = Core.mmio_read(c, 0, 1, bar_id: 3)
    b = settle(Bench.update(b, :core, fn _ -> c end))
    assert Bench.compare_verilator(b) == :ok
  end
end
