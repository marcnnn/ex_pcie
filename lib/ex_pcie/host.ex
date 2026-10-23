defmodule ExPcie.Host do
  @moduledoc """
  Host-side driver of `ExPcie.RTL.Endpoint` on top of `ExPcie.Device`:
  register access by name, DMA ring setup, pointers and interrupts. It
  needs nothing but BAR0 access, DMA buffers and interrupt notification,
  so it runs on any `ExPcie.Device` backend (the `:sysfs` backend has no
  DMA or interrupts, the `:mock` backend with `ExPcie.Sim.Card` has all).

      {:ok, dev} = ExPcie.Device.open(:vfio, bdf: "0000:03:00.0")
      {:ok, ring} = ExPcie.Device.alloc_dma(dev, 64 * 1024)
      :ok = ExPcie.Host.check_id(dev)
      :ok = ExPcie.Host.start_c2h(dev, ring, ring: 65_536, period: 1_024)
      :ok = ExPcie.Device.subscribe_irq(dev, ExPcie.Host.vector(:c2h))
      receive do {:ex_pcie_irq, _, 1} -> ExPcie.Host.ptr(dev, :c2h) end

  The MSI-X table lives in BAR0 (`ExPcie.RTL.Endpoint`) but is written by
  the kernel when interrupts are enabled through vfio (`irq_kind:
  :msix`); this module does not touch it except in `program_msix/4`, for
  environments without a kernel doing it.
  """
  import Bitwise
  alias ExPcie.Device
  alias ExPcie.Device.DmaBuffer
  alias ExPcie.Regs

  @id 0x50434945
  @map Regs.map(32)
  @regs Map.new(@map.registers, &{&1.name, &1.offset})

  @doc "Byte offset of a BAR0 register (`ExPcie.Regs` register map)."
  def offset(name), do: Map.fetch!(@regs, name)

  @doc "Reads a register and splits it into its fields (`ExPcie.Regs.decode/2`)."
  def fields(dev, name), do: ExHdl.Regs.decode(@map, name, read(dev, name))

  @doc "Writes a register from field values (unnamed fields take their reset value)."
  def write_fields(dev, name, fields),
    do: write(dev, name, ExHdl.Regs.encode(@map, name, fields))

  @doc "MSI-X vector of a channel: `:h2c` 0, `:c2h` 1."
  def vector(:h2c), do: 0
  def vector(:c2h), do: 1

  @doc "Reads a register by name."
  def read(dev, name) do
    {:ok, v} = Device.read32(dev, 0, offset(name))
    v
  end

  @doc "Writes a register by name."
  def write(dev, name, value), do: Device.write32(dev, 0, offset(name), value)

  @doc "`:ok` when the ID register reads as this design's."
  def check_id(dev) do
    case read(dev, :id) do
      @id -> :ok
      other -> {:error, {:bad_id, other}}
    end
  end

  @doc """
  Starts the host-to-card channel on `buf` (an `ExPcie.Device` DMA buffer
  whose ring the host fills). Options: `ring:` ring bytes (default the
  buffer size), `period:` bytes per interrupt, `offset:` byte offset of
  the ring in the buffer (0). `ring` and `period` must be multiples of 32
  and `ring` a multiple of `period`; the bus address 32-byte aligned.
  """
  def start_h2c(dev, %DmaBuffer{} = buf, opts), do: start(dev, :h2c, 0, buf, opts)

  @doc "Starts the card-to-host channel on `buf`; options as `start_h2c/3`."
  def start_c2h(dev, %DmaBuffer{} = buf, opts), do: start(dev, :c2h, 1, buf, opts)

  defp start(dev, ch, bit, buf, opts) do
    ring = Keyword.get(opts, :ring, buf.size)
    period = Keyword.fetch!(opts, :period)
    off = Keyword.get(opts, :offset, 0)
    addr = buf.iova + off

    cond do
      rem(addr, 32) != 0 ->
        {:error, :unaligned_base}

      rem(ring, period) != 0 or rem(period, 32) != 0 ->
        {:error, :bad_ring_or_period}

      off + ring > buf.size ->
        {:error, :ring_exceeds_buffer}

      true ->
        write(dev, :"#{ch}_base_lo", addr &&& 0xFFFF_FFFF)
        write(dev, :"#{ch}_base_hi", addr >>> 32)
        write(dev, :"#{ch}_ring", ring)
        write(dev, :"#{ch}_period", period)
        write(dev, :ctrl, read(dev, :ctrl) ||| 1 <<< bit)
    end
  end

  @doc "Stops a channel (`:h2c` or `:c2h`); it restarts from the ring start when started again."
  def stop(dev, :h2c), do: write(dev, :ctrl, read(dev, :ctrl) &&& ~~~1)
  def stop(dev, :c2h), do: write(dev, :ctrl, read(dev, :ctrl) &&& ~~~2)

  @doc "Ring offset in bytes the channel has delivered (`:h2c`, consumed by the card) or completed (`:c2h`, written to host memory)."
  def ptr(dev, :h2c), do: read(dev, :h2c_ptr)
  def ptr(dev, :c2h), do: read(dev, :c2h_ptr)

  @doc "Status bits: `%{h2c_period: bool, c2h_period: bool, h2c_error: bool}`."
  def status(dev) do
    s = read(dev, :status)
    %{h2c_period: (s &&& 1) == 1, c2h_period: (s &&& 2) == 2, h2c_error: (s &&& 4) == 4}
  end

  @doc "Clears the status bits in `mask` (write-1-to-clear)."
  def clear_status(dev, mask \\ 7), do: write(dev, :status, mask)

  @doc "Raises interrupt vector `vec` from software (through the interrupt controller)."
  def force_irq(dev, vec), do: write(dev, :irq_force, 1 <<< vec)

  @doc "Completion errors the H2C channel has seen."
  def h2c_errors(dev), do: read(dev, :h2c_err)

  @doc """
  Bytes between ring offsets `from` and `to` (the C2H pointer), wrapping
  at `ring`, read from the buffer.
  """
  def read_ring(dev, %DmaBuffer{} = buf, ring, from, to, offset \\ 0) do
    if to >= from do
      Device.dma_read(dev, buf, offset + from, to - from)
    else
      with {:ok, a} <- Device.dma_read(dev, buf, offset + from, ring - from),
           {:ok, b} <- Device.dma_read(dev, buf, offset, to),
           do: {:ok, a <> b}
    end
  end

  @doc "Writes `data` into the H2C ring at ring offset `at`, wrapping at `ring`."
  def write_ring(dev, %DmaBuffer{} = buf, ring, at, data, offset \\ 0) do
    n = min(byte_size(data), ring - at)
    <<a::binary-size(n), b::binary>> = data

    with :ok <- Device.dma_write(dev, buf, offset + at, a),
         do: if(b == <<>>, do: :ok, else: write_ring(dev, buf, ring, 0, b, offset))
  end

  @doc "Waits for `{:ex_pcie_irq, dev.id, vector}`; returns `:ok` or `:timeout`."
  def wait_irq(%Device{id: id}, vector, timeout \\ 1_000) do
    receive do
      {:ex_pcie_irq, ^id, ^vector} -> :ok
    after
      timeout -> :timeout
    end
  end

  @doc "Writes MSI-X table entry `vec` (address, data, unmasked) for setups where nothing else programs it."
  def program_msix(dev, vec, addr, data) do
    base = 0x1000 + 16 * vec
    Device.write32(dev, 0, base, addr &&& 0xFFFF_FFFF)
    Device.write32(dev, 0, base + 4, addr >>> 32)
    Device.write32(dev, 0, base + 8, data)
    Device.write32(dev, 0, base + 12, 0)
  end
end
