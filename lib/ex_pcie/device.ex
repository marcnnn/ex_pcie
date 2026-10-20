defmodule ExPcie.Device do
  @moduledoc """
  Access to a PCIe device without a custom kernel driver.

  Backends: `:mock` (in-memory simulated card), `:sysfs` (BAR access through
  `resourceN` files, no DMA or interrupts) and `:vfio` (vfio-pci through the NIF:
  BARs, IOMMU-mapped DMA buffers, MSI/MSI-X).

      {:ok, dev} = ExPcie.Device.open(:mock, bars: %{0 => 4096})
      :ok = ExPcie.Device.write32(dev, 0, 0x10, 0xDEAD)
      {:ok, 0xDEAD} = ExPcie.Device.read32(dev, 0, 0x10)

  Errors are `{:error, reason}`: `:invalid_bar`, `:unaligned`, `:invalid_value`,
  `:out_of_bounds`, `:unsupported`, `:nif_not_loaded` or backend errors.
  Interrupt subscribers receive `{:ex_pcie_irq, dev.id, vector}`.
  """

  defmodule DmaBuffer do
    @moduledoc "Handle of a device-visible buffer: `iova` is the bus address the card uses."
    @enforce_keys [:ref, :iova, :size]
    defstruct [:ref, :iova, :size]
    @type t :: %__MODULE__{ref: term, iova: non_neg_integer, size: pos_integer}
  end

  defmodule Backend do
    @moduledoc "Callbacks of a device backend. Arguments are already validated by `ExPcie.Device`."
    alias ExPcie.Device.DmaBuffer
    @type state :: term
    @callback open(keyword) :: {:ok, state} | {:error, term}
    @callback close(state) :: :ok
    @callback id(state) :: term
    @callback info(state) :: map
    @callback bar_size(state, bar :: 0..5) :: {:ok, non_neg_integer} | {:error, term}
    @callback read32(state, 0..5, non_neg_integer) :: {:ok, non_neg_integer} | {:error, term}
    @callback write32(state, 0..5, non_neg_integer, non_neg_integer) :: :ok | {:error, term}
    @callback read_bytes(state, 0..5, non_neg_integer, non_neg_integer) ::
                {:ok, binary} | {:error, term}
    @callback write_bytes(state, 0..5, non_neg_integer, binary) :: :ok | {:error, term}
    @callback alloc_dma(state, pos_integer) :: {:ok, DmaBuffer.t()} | {:error, term}
    @callback free_dma(state, DmaBuffer.t()) :: :ok | {:error, term}
    @callback dma_write(state, DmaBuffer.t(), non_neg_integer, binary) :: :ok | {:error, term}
    @callback dma_read(state, DmaBuffer.t(), non_neg_integer, non_neg_integer) ::
                {:ok, binary} | {:error, term}
    @callback subscribe_irq(state, non_neg_integer, pid) :: :ok | {:error, term}
    @callback unsubscribe_irq(state, non_neg_integer, pid) :: :ok | {:error, term}
  end

  @enforce_keys [:backend, :state, :id]
  defstruct [:backend, :state, :id]
  @type t :: %__MODULE__{backend: module, state: term, id: term}

  @max_u32 0xFFFF_FFFF

  @doc "Opens a device. `backend` is `:mock | :sysfs | :vfio` or a `Backend` module."
  @spec open(:mock | :sysfs | :vfio | module, keyword) :: {:ok, t} | {:error, term}
  def open(backend, opts \\ []) do
    mod = backend_module(backend)

    with {:ok, state} <- mod.open(opts) do
      {:ok, %__MODULE__{backend: mod, state: state, id: mod.id(state)}}
    end
  end

  @spec close(t) :: :ok
  def close(%{backend: m, state: s}), do: m.close(s)

  @spec info(t) :: map
  def info(%{backend: m, state: s}), do: m.info(s)

  @spec bar_size(t, 0..5) :: {:ok, non_neg_integer} | {:error, term}
  def bar_size(%{backend: m, state: s}, bar) do
    with :ok <- check_bar(bar), do: m.bar_size(s, bar)
  end

  @spec read32(t, 0..5, non_neg_integer) :: {:ok, non_neg_integer} | {:error, term}
  def read32(%{backend: m, state: s}, bar, off) do
    with :ok <- check_bar(bar), :ok <- check_off(off, 4), do: m.read32(s, bar, off)
  end

  @spec write32(t, 0..5, non_neg_integer, non_neg_integer) :: :ok | {:error, term}
  def write32(%{backend: m, state: s}, bar, off, value) do
    with :ok <- check_bar(bar),
         :ok <- check_off(off, 4),
         :ok <- check_u32(value),
         do: m.write32(s, bar, off, value)
  end

  @doc "Reads `len` bytes (multiple of 4) with 32-bit accesses."
  @spec read_bytes(t, 0..5, non_neg_integer, non_neg_integer) :: {:ok, binary} | {:error, term}
  def read_bytes(%{backend: m, state: s}, bar, off, len) do
    with :ok <- check_bar(bar), :ok <- check_off(off, len), do: m.read_bytes(s, bar, off, len)
  end

  @doc "Writes a binary (size multiple of 4) with 32-bit accesses."
  @spec write_bytes(t, 0..5, non_neg_integer, binary) :: :ok | {:error, term}
  def write_bytes(%{backend: m, state: s}, bar, off, bin) when is_binary(bin) do
    with :ok <- check_bar(bar),
         :ok <- check_off(off, byte_size(bin)),
         do: m.write_bytes(s, bar, off, bin)
  end

  @spec alloc_dma(t, pos_integer) :: {:ok, DmaBuffer.t()} | {:error, term}
  def alloc_dma(%{backend: m, state: s}, size) when is_integer(size) and size > 0,
    do: m.alloc_dma(s, size)

  @spec free_dma(t, DmaBuffer.t()) :: :ok | {:error, term}
  def free_dma(%{backend: m, state: s}, %DmaBuffer{} = buf), do: m.free_dma(s, buf)

  @spec dma_write(t, DmaBuffer.t(), non_neg_integer, binary) :: :ok | {:error, term}
  def dma_write(%{backend: m, state: s}, %DmaBuffer{} = buf, off, bin)
      when is_integer(off) and off >= 0 and is_binary(bin) do
    if off + byte_size(bin) > buf.size,
      do: {:error, :out_of_bounds},
      else: m.dma_write(s, buf, off, bin)
  end

  @spec dma_read(t, DmaBuffer.t(), non_neg_integer, non_neg_integer) ::
          {:ok, binary} | {:error, term}
  def dma_read(%{backend: m, state: s}, %DmaBuffer{} = buf, off, len)
      when is_integer(off) and off >= 0 and is_integer(len) and len >= 0 do
    if off + len > buf.size, do: {:error, :out_of_bounds}, else: m.dma_read(s, buf, off, len)
  end

  @doc "Delivers `{:ex_pcie_irq, dev.id, vector}` to `pid` for each interrupt."
  @spec subscribe_irq(t, non_neg_integer, pid) :: :ok | {:error, term}
  def subscribe_irq(%{backend: m, state: s}, vector, pid \\ self())
      when is_integer(vector) and vector >= 0 and is_pid(pid),
      do: m.subscribe_irq(s, vector, pid)

  @spec unsubscribe_irq(t, non_neg_integer, pid) :: :ok | {:error, term}
  def unsubscribe_irq(%{backend: m, state: s}, vector, pid \\ self())
      when is_integer(vector) and vector >= 0 and is_pid(pid),
      do: m.unsubscribe_irq(s, vector, pid)

  defp backend_module(:mock), do: ExPcie.Device.Mock
  defp backend_module(:sysfs), do: ExPcie.Device.Sysfs
  defp backend_module(:vfio), do: ExPcie.Device.Vfio
  defp backend_module(mod) when is_atom(mod), do: mod

  defp check_bar(bar) when is_integer(bar) and bar in 0..5, do: :ok
  defp check_bar(_), do: {:error, :invalid_bar}

  defp check_off(off, len) when is_integer(off) and off >= 0 and is_integer(len) and len >= 0,
    do: if(rem(off, 4) == 0 and rem(len, 4) == 0, do: :ok, else: {:error, :unaligned})

  defp check_off(_, _), do: {:error, :invalid_value}

  defp check_u32(v) when is_integer(v) and v >= 0 and v <= @max_u32, do: :ok
  defp check_u32(_), do: {:error, :invalid_value}
end
