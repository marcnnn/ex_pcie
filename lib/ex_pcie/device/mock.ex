defmodule ExPcie.Device.Mock do
  @moduledoc """
  In-memory device for tests and card models.

  Options: `bars: %{0 => 1_048_576}` (sizes in bytes), `on_read: fn bar, off -> value | :default end`,
  `on_write: fn bar, off, value -> :ok end`. Hooks run in the calling process, so they may call back
  into the mock (e.g. a card model doing `dma_read_iova/3`).

  A card model uses `trigger_irq/2`, `dma_translate/3`, `dma_read_iova/3` and `dma_write_iova/3`
  with the `ExPcie.Device` handle. DMA buffers get 4 KiB-aligned fake IOVAs from a bump allocator
  starting at `0x1_0000_0000`; IOVAs are never reused.
  """
  @behaviour ExPcie.Device.Backend
  alias ExPcie.Device.DmaBuffer

  @iova_base 0x1_0000_0000
  @page 4096

  defstruct [:pid, :id, :bars, :on_read, :on_write]

  @impl true
  def open(opts) do
    bars = Map.new(Keyword.get(opts, :bars, %{0 => 1_048_576}))

    {:ok, pid} =
      Agent.start_link(fn ->
        %{words: %{}, bufs: %{}, next_iova: @iova_base, next_buf: 1, subs: %{}}
      end)

    {:ok,
     %__MODULE__{
       pid: pid,
       id: make_ref(),
       bars: bars,
       on_read: Keyword.get(opts, :on_read),
       on_write: Keyword.get(opts, :on_write)
     }}
  end

  @impl true
  def close(%{pid: pid}) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def id(%{id: id}), do: id

  @impl true
  def info(s) do
    %{backend: :mock, id: s.id, bars: s.bars, dma: true, irq: true}
  end

  @impl true
  def bar_size(s, bar), do: with({:ok, n} <- fetch_bar(s, bar), do: {:ok, n})

  @impl true
  def read32(s, bar, off) do
    with {:ok, size} <- fetch_bar(s, bar), :ok <- in_range(off, 4, size) do
      case s.on_read && s.on_read.(bar, off) do
        v when is_integer(v) -> {:ok, Bitwise.band(v, 0xFFFF_FFFF)}
        _ -> {:ok, Agent.get(s.pid, &Map.get(&1.words, {bar, off}, 0))}
      end
    end
  end

  @impl true
  def write32(s, bar, off, value) do
    with {:ok, size} <- fetch_bar(s, bar), :ok <- in_range(off, 4, size) do
      Agent.update(s.pid, &put_in(&1.words[{bar, off}], value))
      if s.on_write, do: s.on_write.(bar, off, value)
      :ok
    end
  end

  @impl true
  def read_bytes(s, bar, off, len) do
    with {:ok, size} <- fetch_bar(s, bar), :ok <- in_range(off, len, size) do
      words = for o <- word_offsets(off, len), do: elem(read32(s, bar, o), 1)
      {:ok, for(w <- words, into: <<>>, do: <<w::32-little>>)}
    end
  end

  @impl true
  def write_bytes(s, bar, off, bin) do
    with {:ok, size} <- fetch_bar(s, bar), :ok <- in_range(off, byte_size(bin), size) do
      for {<<w::32-little>>, o} <- Enum.zip(chunks(bin), word_offsets(off, byte_size(bin))),
          do: write32(s, bar, o, w)

      :ok
    end
  end

  @impl true
  def alloc_dma(s, size) do
    Agent.get_and_update(s.pid, fn st ->
      iova = st.next_iova
      id = st.next_buf
      span = div(size + @page - 1, @page) * @page
      buf = %DmaBuffer{ref: id, iova: iova, size: size}
      entry = %{buf: buf, data: :binary.copy(<<0>>, size)}

      {{:ok, buf},
       %{st | next_iova: iova + span, next_buf: id + 1, bufs: Map.put(st.bufs, id, entry)}}
    end)
  end

  @impl true
  def free_dma(s, %DmaBuffer{ref: id}) do
    Agent.get_and_update(s.pid, fn st ->
      if Map.has_key?(st.bufs, id),
        do: {:ok, %{st | bufs: Map.delete(st.bufs, id)}},
        else: {{:error, :unknown_buffer}, st}
    end)
  end

  @impl true
  def dma_write(s, %DmaBuffer{ref: id}, off, bin) do
    Agent.get_and_update(s.pid, fn st ->
      case st.bufs do
        %{^id => %{data: d} = e} when off + byte_size(bin) <= byte_size(d) ->
          n = byte_size(bin)
          <<pre::binary-size(off), _::binary-size(n), post::binary>> = d
          {:ok, put_in(st.bufs[id], %{e | data: <<pre::binary, bin::binary, post::binary>>})}

        %{^id => _} ->
          {{:error, :out_of_bounds}, st}

        _ ->
          {{:error, :unknown_buffer}, st}
      end
    end)
  end

  @impl true
  def dma_read(s, %DmaBuffer{ref: id}, off, len) do
    Agent.get(s.pid, fn st ->
      case st.bufs do
        %{^id => %{data: d}} when off + len <= byte_size(d) -> {:ok, binary_part(d, off, len)}
        %{^id => _} -> {:error, :out_of_bounds}
        _ -> {:error, :unknown_buffer}
      end
    end)
  end

  @impl true
  def subscribe_irq(s, vector, pid) do
    Agent.update(s.pid, fn st ->
      %{st | subs: Map.update(st.subs, vector, MapSet.new([pid]), &MapSet.put(&1, pid))}
    end)
  end

  @impl true
  def unsubscribe_irq(s, vector, pid) do
    Agent.update(s.pid, fn st ->
      %{st | subs: Map.update(st.subs, vector, MapSet.new(), &MapSet.delete(&1, pid))}
    end)
  end

  ## card-model side

  @doc "Raises interrupt `vector`: every subscriber gets `{:ex_pcie_irq, dev.id, vector}`."
  @spec trigger_irq(ExPcie.Device.t(), non_neg_integer) :: :ok
  def trigger_irq(%{state: s}, vector) do
    for pid <- Agent.get(s.pid, &MapSet.to_list(Map.get(&1.subs, vector, MapSet.new()))),
        do: send(pid, {:ex_pcie_irq, s.id, vector})

    :ok
  end

  @doc "Finds the buffer holding `[iova, iova+len)`: `{:ok, %DmaBuffer{}, offset}` or `:error`."
  @spec dma_translate(ExPcie.Device.t(), non_neg_integer, non_neg_integer) ::
          {:ok, DmaBuffer.t(), non_neg_integer} | :error
  def dma_translate(%{state: s}, iova, len)
      when is_integer(iova) and is_integer(len) and len >= 0 do
    Agent.get(s.pid, fn st ->
      Enum.find_value(st.bufs, :error, fn {_, %{buf: b}} ->
        if iova >= b.iova and iova + len <= b.iova + b.size, do: {:ok, b, iova - b.iova}
      end)
    end)
  end

  @doc "Bus-master read by IOVA (within one buffer)."
  @spec dma_read_iova(ExPcie.Device.t(), non_neg_integer, non_neg_integer) ::
          {:ok, binary} | {:error, :unmapped}
  def dma_read_iova(%{state: s} = dev, iova, len) do
    case dma_translate(dev, iova, len) do
      {:ok, b, off} -> dma_read(s, b, off, len)
      :error -> {:error, :unmapped}
    end
  end

  @doc "Bus-master write by IOVA (within one buffer)."
  @spec dma_write_iova(ExPcie.Device.t(), non_neg_integer, binary) :: :ok | {:error, :unmapped}
  def dma_write_iova(%{state: s} = dev, iova, bin) when is_binary(bin) do
    case dma_translate(dev, iova, byte_size(bin)) do
      {:ok, b, off} -> dma_write(s, b, off, bin)
      :error -> {:error, :unmapped}
    end
  end

  defp fetch_bar(s, bar) do
    case s.bars do
      %{^bar => size} -> {:ok, size}
      _ -> {:error, :invalid_bar}
    end
  end

  defp in_range(off, len, size),
    do: if(off + len <= size, do: :ok, else: {:error, :out_of_bounds})

  defp word_offsets(off, len), do: Enum.take_every(off..(off + len - 1)//1, 4)

  defp chunks(bin), do: for(<<w::binary-size(4) <- bin>>, do: w)
end
