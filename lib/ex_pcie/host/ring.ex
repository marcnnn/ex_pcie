defmodule ExPcie.Host.Ring do
  @moduledoc """
  Host side of one descriptor ring (`ExPcie.DRing`) on an `ExPcie.Device`:
  the ring and the head write-back block live in one DMA buffer, the
  buffers the descriptors point to are `ExPcie.Device` DMA buffers. The
  struct holds the driver's view (producer index, reap index, what was
  posted); every call returns the updated ring. It runs on any backend
  with DMA (`:vfio`, and `:mock` behind `ExPcie.Sim.Card`); the same logic
  against the model's host memory is `ExPcie.Model.Driver`.

      {:ok, ring} = Ring.open(dev, :c2h, entries: 64, irq: true)
      :ok = Ring.start(ring)
      {:ok, ring} = Ring.post(ring, rx, 0, 4096, [:irq])
      :ok = Ring.doorbell(ring)
      {:ok, ring, done} = Ring.reap(ring)       # [%{buffer:, offset:, bytes:, eop:, error:, cookie:}]

  `open/3` programs the registers but does not start the channel; the
  `desc` and `run` bits are set by `start/1` (the other channel's bits
  are kept). Setup order and rules: `ExPcie.DRing`. The channel is `:h2c`
  or `:c2h` of pair 0, `ExPcie.Regs.channel/2` names the ones of another
  pair (`Ring.open(dev, Regs.channel(:c2h, 1))`), which use that pair's
  registers.
  """
  import Bitwise

  alias ExPcie.{Device, DRing, Host, Regs}
  alias ExPcie.Device.DmaBuffer

  defstruct [:dev, :ch, :buf, :entries, :wb_off, :wb, head: 0, reaped: 0, posted: %{}]

  @type t :: %__MODULE__{}

  @doc """
  Allocates the ring and programs `dbase`, `dsize`, `wb` and `dctrl`.
  Options: `entries:` (64), `wb:` `:both` (default), `:desc`, `:head`,
  `:none`, `irq:` (false).
  """
  @spec open(Device.t(), atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(dev, ch, opts \\ []) when is_atom(ch) do
    _ = Regs.split_channel(ch)
    entries = Keyword.get(opts, :entries, 64)
    wb = Keyword.get(opts, :wb, :both)
    wb_off = entries * DRing.size()

    with {:ok, buf} <- Device.alloc_dma(dev, wb_off + 64),
         :ok <- Device.dma_write(dev, buf, 0, :binary.copy(<<0>>, wb_off + 64)) do
      ring = buf.iova
      wb_addr = buf.iova + wb_off

      ctrl = [
        wb_desc: bit(wb in [:both, :desc]),
        wb_head: bit(wb in [:both, :head]),
        irq_en: bit(Keyword.get(opts, :irq, false))
      ]

      Host.write(dev, :"#{ch}_dbase_lo", ring &&& 0xFFFF_FFFF)
      Host.write(dev, :"#{ch}_dbase_hi", ring >>> 32)
      Host.write(dev, :"#{ch}_dsize", entries)
      Host.write(dev, :"#{ch}_wb_lo", wb_addr &&& 0xFFFF_FFFF)
      Host.write(dev, :"#{ch}_wb_hi", wb_addr >>> 32)
      Host.write_fields(dev, :"#{ch}_dctrl", ctrl)

      {:ok, %__MODULE__{dev: dev, ch: ch, buf: buf, entries: entries, wb_off: wb_off, wb: wb}}
    end
  end

  defp bit(true), do: 1
  defp bit(false), do: 0

  @doc "Sets the `desc` and `run` bits of the channel."
  def start(%__MODULE__{dev: dev, ch: ch}) do
    {run, desc} = bits(ch)
    ctrl = ctrl(ch)
    Host.write(dev, ctrl, Host.read(dev, ctrl) ||| run ||| desc)
  end

  @doc "Clears the run bit (the card resets the ring) and restarts the indices."
  def stop(%__MODULE__{dev: dev, ch: ch} = r) do
    {run, _} = bits(ch)
    ctrl = ctrl(ch)
    :ok = Host.write(dev, ctrl, Host.read(dev, ctrl) &&& ~~~run)
    %{r | head: 0, reaped: 0, posted: %{}}
  end

  defp bits(ch), do: if(elem(Regs.split_channel(ch), 0) == :h2c, do: {1, 4}, else: {2, 8})

  defp ctrl(ch), do: Regs.pair_reg(:ctrl, elem(Regs.split_channel(ch), 1))

  @doc "Descriptors that can still be posted."
  def space(%__MODULE__{} = r), do: r.entries - 1 - rem(r.head - r.reaped + r.entries, r.entries)

  @doc """
  Posts a descriptor for `len` bytes of `buf` at byte `offset` (the bus
  address and `len` must be multiples of 32). `flags` as for
  `ExPcie.DRing.encode/4`. `{:error, :full}` when the ring has no room.
  The doorbell is not rung.
  """
  @spec post(t(), DmaBuffer.t(), non_neg_integer(), pos_integer(), term(), non_neg_integer()) ::
          {:ok, t()} | {:error, term()}
  def post(%__MODULE__{} = r, %DmaBuffer{} = buf, offset, len, flags \\ [], cookie \\ 0) do
    addr = buf.iova + offset

    cond do
      rem(addr, 32) != 0 or rem(len, 32) != 0 or len == 0 -> {:error, :unaligned}
      offset + len > buf.size -> {:error, :beyond_buffer}
      space(r) == 0 -> {:error, :full}
      true -> do_post(r, buf, offset, addr, len, flags, cookie)
    end
  end

  defp do_post(r, buf, offset, addr, len, flags, cookie) do
    idx = r.head
    desc = DRing.encode(addr, len, flags, cookie)

    with :ok <- Device.dma_write(r.dev, r.buf, idx * DRing.size(), desc) do
      info = %{buffer: buf, offset: offset, len: len, cookie: cookie}
      {:ok, %{r | head: rem(idx + 1, r.entries), posted: Map.put(r.posted, idx, info)}}
    end
  end

  @doc "Rings the doorbell (writes the producer index)."
  def doorbell(%__MODULE__{dev: dev, ch: ch, head: head}),
    do: Host.write(dev, :"#{ch}_dhead", head)

  @doc """
  Completed descriptors in order: `{:ok, ring, [completion]}` with
  `index`, `buffer`, `offset`, `bytes` (transferred), `eop`, `error`
  and `cookie`. With `wb: :head` only the head block tells how far the
  card got (`bytes` is the posted length). Reaped descriptors are cleared.
  """
  def reap(%__MODULE__{} = r), do: reap(r, [])

  defp reap(%{reaped: n, head: n} = r, acc), do: {:ok, r, Enum.reverse(acc)}

  defp reap(r, acc) do
    {:ok, bin} = Device.dma_read(r.dev, r.buf, r.reaped * DRing.size(), DRing.size())
    info = Map.fetch!(r.posted, r.reaped)
    desc = DRing.decode(bin)
    desc = if r.wb == :head, do: head_status(r, desc, info), else: desc

    if desc.done do
      :ok = Device.dma_write(r.dev, r.buf, r.reaped * DRing.size() + 24, <<0::64>>)

      done = %{
        index: r.reaped,
        buffer: info.buffer,
        offset: info.offset,
        bytes: desc.bytes,
        eop: desc.eop,
        error: desc.error,
        cookie: info.cookie
      }

      reap(
        %{r | reaped: rem(r.reaped + 1, r.entries), posted: Map.delete(r.posted, r.reaped)},
        [done | acc]
      )
    else
      {:ok, r, Enum.reverse(acc)}
    end
  end

  defp head_status(r, desc, info) do
    {:ok, hb} = Device.dma_read(r.dev, r.buf, r.wb_off, 8)
    %{tail: tail} = DRing.decode_head(hb)
    outstanding = rem(r.head - r.reaped + r.entries, r.entries)
    completed = rem(tail - r.reaped + r.entries, r.entries)
    %{desc | done: completed > 0 and completed <= outstanding, bytes: info.len}
  end

  @doc "The head write-back block `%{tail:, count:}` as the card wrote it."
  def head(%__MODULE__{dev: dev, buf: buf, wb_off: off}) do
    {:ok, hb} = Device.dma_read(dev, buf, off, 8)
    DRing.decode_head(hb)
  end

  @doc "Registers of the ring: `%{tail:, completed:, fetch:, halted:, bad_desc:, fetch_error:}`."
  def status(%__MODULE__{dev: dev, ch: ch}) do
    s = Host.fields(dev, :"#{ch}_dstat")

    %{
      tail: Host.read(dev, :"#{ch}_dtail"),
      completed: Host.read(dev, :"#{ch}_dcount"),
      fetch: Host.read(dev, :"#{ch}_dfetch"),
      halted: s.halted == 1,
      bad_desc: s.bad_desc == 1,
      fetch_error: s.fetch_error == 1
    }
  end

  @doc "Frees the ring buffer (the channel must be stopped)."
  def close(%__MODULE__{dev: dev, buf: buf}), do: Device.free_dma(dev, buf)
end
