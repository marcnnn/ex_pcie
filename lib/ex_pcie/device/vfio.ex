defmodule ExPcie.Device.Vfio do
  @moduledoc """
  vfio-pci backend (needs the NIF, the device bound to `vfio-pci` and an enabled IOMMU).

  Options: `bdf:` (required), `hugepages: false` (DMA buffers from 2 MiB pages),
  `irq_kind: :msix | :msi` (default tries MSI-X then MSI), `irq_vectors:` (default 32, capped by
  the device). Interrupts are received through eventfds by a relay process that forwards
  `{:ex_pcie_irq, dev.id, vector}`; the relay starts on the first `subscribe_irq/3`.
  """
  @behaviour ExPcie.Device.Backend
  alias ExPcie.Device.DmaBuffer
  alias ExPcie.Nif

  defstruct [:id, :dev, :bars, :opts, :irq]

  @impl true
  def open(opts) do
    with true <- Nif.loaded?() or {:error, :nif_not_loaded},
         bdf when is_binary(bdf) <- opts[:bdf] || {:error, :missing_bdf},
         {:ok, dev} <- Nif.vfio_open(bdf) do
      bars = for n <- 0..5, {:ok, bar} <- [Nif.vfio_map_bar(dev, n)], into: %{}, do: {n, bar}
      id = make_ref()
      {:ok, irq} = Agent.start_link(fn -> nil end)
      {:ok, %__MODULE__{id: id, dev: dev, bars: bars, opts: opts, irq: irq}}
    else
      {:error, _} = e -> e
      _ -> {:error, :invalid_options}
    end
  end

  @impl true
  def close(s) do
    case Agent.get(s.irq, & &1) do
      nil -> :ok
      relay -> GenServer.stop(relay)
    end

    Agent.stop(s.irq)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def id(%{id: id}), do: id

  @impl true
  def info(s) do
    sizes = Map.new(s.bars, fn {n, b} -> {n, Nif.bar_size(b)} end)
    %{backend: :vfio, id: s.id, bdf: s.opts[:bdf], bars: sizes, dma: true, irq: true}
  end

  @impl true
  def bar_size(s, bar), do: with({:ok, b} <- fetch(s, bar), do: {:ok, Nif.bar_size(b)})

  @impl true
  def read32(s, bar, off), do: with({:ok, b} <- fetch(s, bar), do: Nif.bar_read32(b, off))

  @impl true
  def write32(s, bar, off, v), do: with({:ok, b} <- fetch(s, bar), do: Nif.bar_write32(b, off, v))

  @impl true
  def read_bytes(s, bar, off, len),
    do: with({:ok, b} <- fetch(s, bar), do: Nif.bar_read(b, off, len))

  @impl true
  def write_bytes(s, bar, off, bin),
    do: with({:ok, b} <- fetch(s, bar), do: Nif.bar_write(b, off, bin))

  @impl true
  def alloc_dma(s, size) do
    with {:ok, ref, iova} <- Nif.dma_alloc(s.dev, size, Keyword.get(s.opts, :hugepages, false)) do
      {:ok, %DmaBuffer{ref: ref, iova: iova, size: size}}
    end
  end

  @impl true
  def free_dma(_s, %DmaBuffer{ref: ref}), do: Nif.dma_free(ref)

  @impl true
  def dma_write(_s, %DmaBuffer{ref: ref}, off, bin), do: Nif.dma_write(ref, off, bin)

  @impl true
  def dma_read(_s, %DmaBuffer{ref: ref}, off, len), do: Nif.dma_read(ref, off, len)

  @impl true
  def subscribe_irq(s, vector, pid) do
    with {:ok, relay} <- relay(s), do: GenServer.call(relay, {:subscribe, vector, pid})
  end

  @impl true
  def unsubscribe_irq(s, vector, pid) do
    with {:ok, relay} <- relay(s), do: GenServer.call(relay, {:unsubscribe, vector, pid})
  end

  defp fetch(s, bar) do
    case s.bars do
      %{^bar => b} -> {:ok, b}
      _ -> {:error, :invalid_bar}
    end
  end

  defp relay(s) do
    Agent.get_and_update(s.irq, fn
      nil ->
        case GenServer.start_link(__MODULE__.Irq, {s.dev, s.id, s.opts}) do
          {:ok, pid} -> {{:ok, pid}, pid}
          {:error, _} = e -> {e, nil}
        end

      pid ->
        {{:ok, pid}, pid}
    end)
  end

  defmodule Irq do
    @moduledoc false
    use GenServer
    alias ExPcie.Nif

    @impl true
    def init({dev, id, opts}) do
      kinds = if k = opts[:irq_kind], do: [k], else: [:msix, :msi]

      with {:ok, kind, count} <- pick(dev, kinds),
           n = min(count, Keyword.get(opts, :irq_vectors, 32)),
           {:ok, evts} <- new_evts(n),
           :ok <- Nif.vfio_irq_enable(dev, kind, Enum.map(evts, &elem(&1, 1))) do
        for {_, e} <- evts, do: :ok = Nif.irq_subscribe(e, self(), :relay)
        {:ok, %{dev: dev, id: id, kind: kind, evts: Map.new(evts), subs: %{}}}
      else
        {:error, reason} -> {:stop, reason}
      end
    end

    @impl true
    def handle_call({:subscribe, v, pid}, _from, st) do
      if Map.has_key?(st.evts, v) do
        {:reply, :ok,
         %{st | subs: Map.update(st.subs, v, MapSet.new([pid]), &MapSet.put(&1, pid))}}
      else
        {:reply, {:error, :invalid_vector}, st}
      end
    end

    def handle_call({:unsubscribe, v, pid}, _from, st),
      do:
        {:reply, :ok, %{st | subs: Map.update(st.subs, v, MapSet.new(), &MapSet.delete(&1, pid))}}

    @impl true
    def handle_info({:ex_pcie_irq, :relay, v}, st) do
      with {:ok, e} <- Map.fetch(st.evts, v), {:ok, n} <- Nif.irq_ack(e) do
        for pid <- Map.get(st.subs, v, []),
            _ <- 1..max(n, 1),
            do: send(pid, {:ex_pcie_irq, st.id, v})
      end

      {:noreply, st}
    end

    def handle_info(_, st), do: {:noreply, st}

    @impl true
    def terminate(_, st) do
      Nif.vfio_irq_disable(st.dev, st.kind)
      for {_, e} <- st.evts, do: Nif.eventfd_close(e)
    end

    defp pick(_dev, []), do: {:error, :no_interrupts}

    defp pick(dev, [kind | rest]) do
      case Nif.vfio_irq_count(dev, kind) do
        {:ok, c} when c > 0 -> {:ok, kind, c}
        _ -> pick(dev, rest)
      end
    end

    defp new_evts(n) do
      Enum.reduce_while(0..(n - 1), {:ok, []}, fn v, {:ok, acc} ->
        case Nif.eventfd_new(v) do
          {:ok, e} -> {:cont, {:ok, [{v, e} | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end
end
