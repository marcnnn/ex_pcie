defmodule ExPcie.Device.Sysfs do
  @moduledoc """
  BAR access through `<sysfs_root>/<bdf>/resource<N>`. No DMA, no interrupts.

  Options: `bdf:` (required, e.g. `"0000:03:00.0"`), `sysfs_root:` (default
  `/sys/bus/pci/devices`), `mmap: true` (use the NIF mmap when loaded, otherwise
  pread/pwrite on the resource file). Bounds are checked against the file size.
  """
  @behaviour ExPcie.Device.Backend
  alias ExPcie.Nif

  defstruct [:id, :bdf, :root, :bars]

  @impl true
  def open(opts) do
    with {:ok, bdf} <- fetch_bdf(opts) do
      root = Keyword.get(opts, :sysfs_root, "/sys/bus/pci/devices")
      dir = Path.join(root, bdf)

      if File.dir?(dir) do
        use_mmap = Keyword.get(opts, :mmap, true) and Nif.loaded?()

        bars =
          for n <- 0..5,
              bar = open_bar(Path.join(dir, "resource#{n}"), use_mmap),
              into: %{},
              do: {n, bar}

        {:ok, %__MODULE__{id: make_ref(), bdf: bdf, root: root, bars: bars}}
      else
        {:error, :enoent}
      end
    end
  end

  @impl true
  def close(_), do: :ok

  @impl true
  def id(%{id: id}), do: id

  @impl true
  def info(s) do
    sizes = Map.new(s.bars, fn {n, {_, _, size}} -> {n, size} end)
    mode = if Enum.any?(s.bars, &match?({_, {:mmap, _, _}}, &1)), do: :mmap, else: :file
    %{backend: :sysfs, id: s.id, bdf: s.bdf, bars: sizes, access: mode, dma: false, irq: false}
  end

  @impl true
  def bar_size(s, bar), do: with({:ok, {_, _, size}} <- fetch(s, bar), do: {:ok, size})

  @impl true
  def read32(s, bar, off) do
    with {:ok, b} <- fetch(s, bar), {:ok, <<v::32-little>>} <- do_read(b, off, 4), do: {:ok, v}
  end

  @impl true
  def write32(s, bar, off, v) do
    with {:ok, b} <- fetch(s, bar), do: do_write(b, off, <<v::32-little>>)
  end

  @impl true
  def read_bytes(s, bar, off, len) do
    with {:ok, b} <- fetch(s, bar), do: do_read(b, off, len)
  end

  @impl true
  def write_bytes(s, bar, off, bin) do
    with {:ok, b} <- fetch(s, bar), do: do_write(b, off, bin)
  end

  @impl true
  def alloc_dma(_, _), do: {:error, :unsupported}
  @impl true
  def free_dma(_, _), do: {:error, :unsupported}
  @impl true
  def dma_write(_, _, _, _), do: {:error, :unsupported}
  @impl true
  def dma_read(_, _, _, _), do: {:error, :unsupported}
  @impl true
  def subscribe_irq(_, _, _), do: {:error, :unsupported}
  @impl true
  def unsubscribe_irq(_, _, _), do: {:error, :unsupported}

  defp fetch_bdf(opts) do
    case Keyword.get(opts, :bdf) do
      bdf when is_binary(bdf) ->
        if Regex.match?(~r/\A[0-9a-fA-F:.]{7,16}\z/, bdf),
          do: {:ok, bdf},
          else: {:error, :invalid_bdf}

      _ ->
        {:error, :missing_bdf}
    end
  end

  # returns {kind, handle, size} or nil when the resource is absent or empty
  defp open_bar(path, use_mmap) do
    with {:ok, %File.Stat{size: size, type: :regular}} when size > 0 <- File.stat(path) do
      with true <- use_mmap, {:ok, bar} <- Nif.mmap_file(path, 0) do
        {:mmap, bar, size}
      else
        _ -> {:file, path, size}
      end
    else
      _ -> nil
    end
  end

  defp fetch(s, bar) do
    case s.bars do
      %{^bar => b} -> {:ok, b}
      _ -> {:error, :invalid_bar}
    end
  end

  defp bounds(off, len, size), do: if(off + len <= size, do: :ok, else: {:error, :out_of_bounds})

  defp do_read({kind, h, size}, off, len) do
    with :ok <- bounds(off, len, size) do
      case kind do
        :mmap -> Nif.bar_read(h, off, len)
        :file -> file_op(h, fn f -> :file.pread(f, off, len) end, len)
      end
    end
  end

  defp do_write({kind, h, size}, off, bin) do
    with :ok <- bounds(off, byte_size(bin), size) do
      case kind do
        :mmap -> Nif.bar_write(h, off, bin)
        :file -> file_op(h, fn f -> :file.pwrite(f, off, bin) end, :ok)
      end
    end
  end

  defp file_op(path, fun, want) do
    case :file.open(path, [:read, :write, :raw, :binary]) do
      {:ok, f} ->
        try do
          case fun.(f) do
            {:ok, data} when is_binary(data) and is_integer(want) and byte_size(data) == want ->
              {:ok, data}

            {:ok, _} when is_integer(want) ->
              {:error, :short_read}

            :ok ->
              :ok

            :eof ->
              {:error, :short_read}

            {:error, _} = e ->
              e
          end
        after
          :file.close(f)
        end

      {:error, _} = e ->
        e
    end
  end
end
