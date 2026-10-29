defmodule ExPcie.Model.Driver do
  @moduledoc """
  A model of the host driver for the descriptor rings (`ExPcie.DRing`): it
  builds rings, buffers and descriptors in the host memory of an
  `ExPcie.Model.Core`, programs the endpoint's registers with MMIO writes
  through the core model, rings doorbells and reaps completions the way a
  real driver reads them from host memory. It is a plain value: every
  function takes the core and the driver state and returns both, and
  tests put the core back into a bench with `ExPcie.Model.Bench.update/3`.

      drv = Driver.new()
      {core, drv} = Driver.setup(core, drv, :c2h, entries: 8, wb: :both, irq: true)
      {core, drv} = Driver.start(core, drv, :c2h)
      {core, drv, _} = Driver.post_buffer(core, drv, :c2h, 256, [:irq])
      core = Driver.doorbell(core, drv, :c2h)
      # ... run the bench ...
      {core, drv, done} = Driver.reap(core, drv, :c2h)

  `setup/4` allocates the ring and the write-back block from a bump
  allocator (`arena:` option of `new/1`) and writes `dbase`, `dsize`,
  `wb` and `dctrl`; `start/3` sets the `desc` and `run` bits of the
  pair's `ctrl` register (the bits of the other channel are kept). The
  channel atom (`:h2c`, `:c2h1`, ...) is the key of everything per ring,
  so several pairs share one driver value. `post/6` writes a descriptor
  and advances the producer index without touching the doorbell, so a
  batch needs one `doorbell/3`. Ring space: at most `entries - 1`
  descriptors are outstanding.
  """
  import Bitwise

  alias ExPcie.{DRing, Regs}
  alias ExPcie.Model.Core

  defstruct next: 0x10_0000_0000, rings: %{}, ctrl: %{}, tmo: nil

  @doc "New driver; `arena:` is the first host address of its allocator."
  def new(opts \\ []), do: %__MODULE__{next: Keyword.get(opts, :arena, 0x10_0000_0000)}

  @doc "Allocates `bytes` of host memory aligned to `align` (default 4096); returns `{drv, address}`."
  def alloc(%__MODULE__{} = d, bytes, align \\ 4096) do
    addr = div(d.next + align - 1, align) * align
    {%{d | next: addr + bytes}, addr}
  end

  @doc """
  Builds the ring of `ch` (`:h2c` or `:c2h`; for another channel pair
  `ExPcie.Regs.channel/2`, e.g. `:c2h1`) and programs `dbase`, `dsize`,
  `wb` and `dctrl`. Options: `entries:` (8), `wb:` `:both` (default), `:desc`
  (status into the descriptors), `:head` (head block) or `:none`, `irq:`
  (`irq_en`, default false).
  """
  def setup(%Core{} = core, %__MODULE__{} = d, ch, opts \\ []) do
    entries = Keyword.get(opts, :entries, 8)
    wb = Keyword.get(opts, :wb, :both)
    {d, ring} = alloc(d, entries * DRing.size())
    {d, wbaddr} = alloc(d, 64, 64)
    core = Core.put_mem(core, ring, :binary.copy(<<0>>, entries * DRing.size()))
    core = Core.put_mem(core, wbaddr, <<0::64>>)
    wb_desc = if wb in [:both, :desc], do: 1, else: 0
    wb_head = if wb in [:both, :head], do: 1, else: 0
    irq = if Keyword.get(opts, :irq, false), do: 1, else: 0

    core =
      core
      |> w(:"#{ch}_dbase_lo", ring &&& 0xFFFF_FFFF)
      |> w(:"#{ch}_dbase_hi", ring >>> 32)
      |> w(:"#{ch}_dsize", entries)
      |> w(:"#{ch}_wb_lo", wbaddr &&& 0xFFFF_FFFF)
      |> w(:"#{ch}_wb_hi", wbaddr >>> 32)
      |> w(
        :"#{ch}_dctrl",
        Regs.encode(:"#{ch}_dctrl", wb_desc: wb_desc, wb_head: wb_head, irq_en: irq)
      )

    st = %{
      ring: ring,
      wb: wbaddr,
      entries: entries,
      head: 0,
      reaped: 0,
      posted: %{},
      wb_mode: wb
    }

    {core, %{d | rings: Map.put(d.rings, ch, st)}}
  end

  @doc "Sets the `desc` and `run` bits of `ch` in `ctrl` (the other channel's bits are kept)."
  def start(%Core{} = core, %__MODULE__{} = d, ch) do
    {reg, v} = ctrl_update(d, ch, &(&1 ||| run_bit(ch) ||| desc_bit(ch)))
    {w(core, reg, v), %{d | ctrl: Map.put(d.ctrl, reg, v)}}
  end

  @doc "Clears the run bit of `ch` (the card resets the ring); the driver's indices restart too."
  def stop(%Core{} = core, %__MODULE__{} = d, ch) do
    {reg, v} = ctrl_update(d, ch, &(&1 &&& ~~~run_bit(ch)))
    d = %{d | ctrl: Map.put(d.ctrl, reg, v)}
    ring = %{d.rings[ch] | head: 0, reaped: 0, posted: %{}}
    {w(core, reg, v), %{d | rings: Map.put(d.rings, ch, ring)}}
  end

  @doc "Programs the completion timeout register (cycles)."
  def set_timeout(%Core{} = core, cycles), do: w(core, :timeout, cycles)

  @doc "Descriptors that can still be posted on `ch`."
  def space(%__MODULE__{rings: r}, ch) do
    st = Map.fetch!(r, ch)
    st.entries - 1 - rem(st.head - st.reaped + st.entries, st.entries)
  end

  @doc """
  Writes a descriptor for a buffer (`addr`, `len`) with `flags` (`:irq`,
  `:stop` or an integer) and advances the producer index. Returns
  `{core, drv, index}` or `{:error, :full}`. The doorbell is not rung.
  """
  def post(%Core{} = core, %__MODULE__{} = d, ch, addr, len, flags \\ [], cookie \\ 0) do
    st = Map.fetch!(d.rings, ch)

    if space(d, ch) == 0 do
      {:error, :full}
    else
      idx = st.head

      core =
        Core.put_mem(core, st.ring + idx * DRing.size(), DRing.encode(addr, len, flags, cookie))

      posted = Map.put(st.posted, idx, %{addr: addr, len: len, cookie: cookie})
      st = %{st | head: rem(idx + 1, st.entries), posted: posted}
      {core, %{d | rings: Map.put(d.rings, ch, st)}, idx}
    end
  end

  @doc """
  H2C: copies `data` into a new buffer and posts it on `ch` (default
  `:h2c`, pair 0). Returns `{core, drv, index}`.
  """
  def post_data(%Core{} = core, %__MODULE__{} = d, data, flags \\ [], cookie \\ 0, ch \\ :h2c) do
    {d, addr} = alloc(d, byte_size(data), 32)
    core = Core.put_mem(core, addr, data)
    post(core, d, ch, addr, byte_size(data), flags, cookie)
  end

  @doc "C2H: posts a new empty buffer of `len` bytes. Returns `{core, drv, index}`."
  def post_buffer(%Core{} = core, %__MODULE__{} = d, ch, len, flags \\ [], cookie \\ 0) do
    {d, addr} = alloc(d, len, 32)
    core = Core.put_mem(core, addr, :binary.copy(<<0>>, len))
    post(core, d, ch, addr, len, flags, cookie)
  end

  @doc "Rings the doorbell: writes the producer index to `<ch>_dhead`."
  def doorbell(%Core{} = core, %__MODULE__{} = d, ch),
    do: w(core, :"#{ch}_dhead", Map.fetch!(d.rings, ch).head)

  @doc """
  Completed descriptors in ring order, as the driver sees them in host
  memory: `{core, drv, [completion]}` where each completion has the
  decoded descriptor (`ExPcie.DRing.decode/1`), its `index`, the buffer
  `data` (`bytes` bytes at the buffer address) and the `cookie` it was
  posted with. Reaped descriptors are cleared (DWords 6 and 7) and their
  space becomes available. With `wb: :head` only the head block tells how
  far the card got; `bytes` is then the posted length and `eop`/`error`
  are not known.
  """
  def reap(%Core{} = core, %__MODULE__{} = d, ch) do
    st = Map.fetch!(d.rings, ch)
    {core, st, out} = reap_loop(core, st, [])
    {core, %{d | rings: Map.put(d.rings, ch, st)}, Enum.reverse(out)}
  end

  defp reap_loop(core, st, acc) do
    if st.reaped == st.head do
      {core, st, acc}
    else
      at = st.ring + st.reaped * DRing.size()
      desc = DRing.decode(Core.read_mem(core, at, DRing.size()))
      info = Map.fetch!(st.posted, st.reaped)

      # head-only write-back: the descriptors carry no status, the head block says how far the card got
      desc =
        if st.wb_mode == :head,
          do: head_desc(core, st, desc, info),
          else: desc

      if desc.done do
        data = Core.read_mem(core, info.addr, min(desc.bytes, info.len))
        core = Core.put_mem(core, at + 24, <<0::64>>)

        done =
          Map.merge(desc, %{index: st.reaped, data: data, cookie: info.cookie, buffer: info.addr})

        st = %{
          st
          | reaped: rem(st.reaped + 1, st.entries),
            posted: Map.delete(st.posted, st.reaped)
        }

        reap_loop(core, st, [done | acc])
      else
        {core, st, acc}
      end
    end
  end

  # done when the card's tail index has moved past this descriptor (modulo the ring)
  defp head_desc(core, st, desc, info) do
    %{tail: tail} = DRing.decode_head(Core.read_mem(core, st.wb, 8))
    outstanding = rem(st.head - st.reaped + st.entries, st.entries)
    completed = rem(tail - st.reaped + st.entries, st.entries)
    done = completed > 0 and completed <= outstanding
    %{desc | done: done, bytes: info.len}
  end

  @doc "The head write-back block as the host reads it: `%{tail:, count:}`."
  def head_block(%Core{} = core, %__MODULE__{} = d, ch),
    do: DRing.decode_head(Core.read_mem(core, Map.fetch!(d.rings, ch).wb, 8))

  defp ctrl_update(d, ch, f) do
    reg = Regs.pair_reg(:ctrl, elem(Regs.split_channel(ch), 1))
    {reg, f.(Map.get(d.ctrl, reg, 0))}
  end

  defp run_bit(ch), do: if(elem(Regs.split_channel(ch), 0) == :h2c, do: 1, else: 2)
  defp desc_bit(ch), do: if(elem(Regs.split_channel(ch), 0) == :h2c, do: 4, else: 8)

  defp w(core, reg, v), do: Core.mmio_write(core, Regs.offset(reg), v)
end
