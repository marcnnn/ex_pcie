defmodule ExPcie.Sim.Card do
  @moduledoc """
  A simulated card behind a `:mock` `ExPcie.Device`: the real endpoint RTL
  (`ExPcie.RTL.Endpoint`, in the BEAM simulator) with the hard block model
  (`ExPcie.Model.Core`) around it. BAR0 accesses through the device become
  host requests on CQ and run the simulation until they complete; the
  card's DMA reads and writes reach the device's DMA buffers by IOVA;
  interrupts become `{:ex_pcie_irq, id, vector}` messages. The whole
  host stack (`ExPcie.Host`) therefore runs against the RTL without
  hardware.

      {:ok, dev, card} = ExPcie.Sim.Card.open(loopback: true)
      {:ok, buf} = ExPcie.Device.alloc_dma(dev, 4096)
      :ok = ExPcie.Host.start_c2h(dev, buf, period: 512)
      ExPcie.Sim.Card.advance(card, 2_000)

  Time passes only inside BAR0 accesses and `advance/2`. Options of
  `open/1`: `loopback:` (default true; the user streams are looped
  inside the endpoint; without it feed and drain them through your own
  `ExPcie.Model.Stream` agents with `agents:`), `pairs:` (channel pairs,
  default 1; with `loopback` every pair loops its own streams),
  `seg_last:` (as `ExPcie.RTL.Endpoint`), `vectors:` (`2 * pairs`), and
  every option of `ExPcie.Model.Core.new/1` (`seed`, `mps`, `latency`,
  `rc_valid`, ...). The simulated "kernel" assigns MSI-X vector `v` the
  address `0xFEE00000 + 16 v` and data `0x4000 + v` and writes the table.
  """
  use GenServer
  alias ExPcie.Device
  alias ExPcie.Device.Mock
  alias ExPcie.Model.{Bench, Core}
  alias ExPcie.RTL.Endpoint

  @timeout 120_000

  @doc "Starts the card and returns `{:ok, device, card}`."
  def open(opts \\ []) do
    {:ok, card} = GenServer.start_link(__MODULE__, opts)

    {:ok, dev} =
      Device.open(:mock,
        bars: %{0 => 16_384},
        on_read: fn 0, off -> GenServer.call(card, {:read, off}, @timeout) end,
        on_write: fn 0, off, v -> GenServer.call(card, {:write, off, v}, @timeout) end
      )

    :ok = GenServer.call(card, {:attach, dev}, @timeout)
    {:ok, dev, card}
  end

  @doc "Runs `cycles` clock cycles."
  def advance(card, cycles), do: GenServer.call(card, {:advance, cycles}, @timeout)

  @doc "The hard block model (host memory aside), for statistics and error checks."
  def core(card), do: GenServer.call(card, :core, @timeout)

  @doc "Current clock cycle."
  def cycle(card), do: GenServer.call(card, :cycle, @timeout)

  # -- server ------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    pairs = Keyword.get(opts, :pairs, 1)
    vectors = Keyword.get(opts, :vectors, 2 * pairs)
    loopback = Keyword.get(opts, :loopback, true)
    core_opts = Keyword.drop(opts, [:vectors, :loopback, :agents, :pairs, :seg_last])

    mod =
      Endpoint.build(
        vectors: vectors,
        loopback: loopback,
        pairs: pairs,
        seg_last: Keyword.get(opts, :seg_last, false)
      )

    {:ok,
     %{
       mod: mod,
       core_opts: core_opts,
       agents: Keyword.get(opts, :agents, []),
       bench: nil,
       dev: nil,
       vectors: vectors,
       seen: 0,
       map: %{}
     }}
  end

  @impl true
  def handle_call({:attach, dev}, _from, st) do
    me = self()

    core =
      Core.new(
        Keyword.merge(
          [
            mem_read: fn a, l -> Mock.dma_read_iova(dev, a, l) end,
            mem_write: fn a, b -> Mock.dma_write_iova(dev, a, b) end,
            msix_enable: true
          ],
          st.core_opts
        )
      )

    bench = Bench.new(st.mod, [core: core] ++ st.agents) |> Bench.run(3)
    st = %{st | bench: bench, dev: dev}
    _ = me

    st =
      Enum.reduce(0..(st.vectors - 1), st, fn v, st ->
        addr = 0xFEE0_0000 + 16 * v
        data = 0x4000 + v
        base = 0x1000 + 16 * v

        st
        |> mmio_write(base, addr)
        |> mmio_write(base + 4, 0)
        |> mmio_write(base + 8, data)
        |> mmio_write(base + 12, 0)
        |> then(&%{&1 | map: Map.put(&1.map, {addr, data}, v)})
      end)

    {:reply, :ok, st}
  end

  def handle_call({:read, off}, _from, st) do
    {c, tag} = Core.mmio_read(core_of(st), off)
    b = Bench.update(st.bench, :core, fn _ -> c end)

    b =
      Bench.run_until(
        b,
        &(Core.mmio_result(Bench.agent(&1, :core), tag) != :pending),
        b.cycle + 20_000
      )

    st = deliver(%{st | bench: b})

    case Core.mmio_result(core_of(st), tag) do
      {:ok, <<v::little-32>>, _} -> {:reply, v, st}
      other -> {:reply, {:error, other}, st}
    end
  end

  def handle_call({:write, off, v}, _from, st), do: {:reply, :ok, mmio_write(st, off, v)}

  def handle_call({:advance, n}, _from, st),
    do: {:reply, :ok, deliver(%{st | bench: Bench.run(st.bench, n)})}

  def handle_call(:core, _from, st), do: {:reply, core_of(st), st}
  def handle_call(:cycle, _from, st), do: {:reply, st.bench.cycle, st}

  defp core_of(st), do: Bench.agent(st.bench, :core)

  defp mmio_write(st, off, v) do
    b = Bench.update(st.bench, :core, &Core.mmio_write(&1, off, v))
    b = Bench.run_until(b, &Core.idle?(Bench.agent(&1, :core)), b.cycle + 20_000) |> Bench.run(24)
    deliver(%{st | bench: b})
  end

  # forward interrupts the model logged since the last look to the mock device
  defp deliver(st) do
    log = Core.irq_log(core_of(st))

    log
    |> Enum.drop(st.seen)
    |> Enum.each(fn {_cycle, {:msix, addr, data}} ->
      case st.map do
        %{{^addr, ^data} => vec} -> Mock.trigger_irq(st.dev, vec)
        _ -> :ok
      end
    end)

    %{st | seen: length(log)}
  end
end
