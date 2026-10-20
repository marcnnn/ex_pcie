defmodule ExPcie.Nif do
  @moduledoc """
  Raw bindings to `c_src/ex_pcie_nif.c`. The NIF is optional: if the shared
  object is missing the module still loads and every function raises
  `:nif_not_loaded`; use `loaded?/0` to check. Prefer `ExPcie.Device`.

  Offsets and lengths are bytes; BAR accesses are 32-bit and 4-byte aligned.
  Errors are `{:error, reason}` with `:out_of_bounds`, `:unaligned`, `:closed`,
  `:unsupported` or an errno atom (`:enoent`, `:eacces`, ...).
  """
  @on_load :load_nif

  @doc false
  def load_nif do
    case :code.priv_dir(:ex_pcie) do
      {:error, _} ->
        :ok

      dir ->
        ["", "native"]
        |> Enum.map(&(dir |> Path.join(&1) |> Path.join("ex_pcie_nif") |> String.to_charlist()))
        |> Enum.find(&File.exists?(&1 ++ ~c".so"))
        |> case do
          nil -> :ok
          path -> _ = :erlang.load_nif(path, 0)
        end

        :ok
    end
  end

  @doc "True when the NIF shared object is loaded."
  @spec loaded?() :: boolean
  def loaded? do
    is_map(capabilities())
  rescue
    ErlangError -> false
  end

  @doc "Map of NIF features (`:version`, `:vfio`, `:mmap_file`, `:eventfd`, `:dma`, `:hugepages`)."
  def capabilities, do: nope()

  # mmap'd regions (sysfs resource files or vfio BARs)
  def mmap_file(_path, _size), do: nope()
  def bar_size(_bar), do: nope()
  def bar_read32(_bar, _off), do: nope()
  def bar_write32(_bar, _off, _val), do: nope()
  def bar_read(_bar, _off, _len), do: nope()
  def bar_write(_bar, _off, _bin), do: nope()

  # DMA buffers; the first argument of dma_alloc is a vfio device or :test_no_iommu
  def dma_alloc(_dev, _size, _hugepage), do: nope()
  def dma_free(_buf), do: nope()
  def dma_info(_buf), do: nope()
  def dma_read(_buf, _off, _len), do: nope()
  def dma_write(_buf, _off, _bin), do: nope()

  # eventfds; irq_subscribe arms enif_select and the pid gets `{:ex_pcie_irq, tag, vector}`
  # once per wakeup; call irq_ack to read the count and re-arm.
  def eventfd_new(_vector), do: nope()
  def eventfd_signal(_evt), do: nope()
  def eventfd_close(_evt), do: nope()
  def irq_subscribe(_evt, _pid, _tag), do: nope()
  def irq_unsubscribe(_evt), do: nope()
  def irq_ack(_evt), do: nope()

  # vfio
  def vfio_open(_bdf), do: nope()
  def vfio_region_info(_dev, _bar), do: nope()
  def vfio_map_bar(_dev, _bar), do: nope()
  def vfio_irq_count(_dev, _kind), do: nope()
  def vfio_irq_enable(_dev, _kind, _evts), do: nope()
  def vfio_irq_disable(_dev, _kind), do: nope()

  defp nope, do: :erlang.nif_error(:nif_not_loaded)
end
