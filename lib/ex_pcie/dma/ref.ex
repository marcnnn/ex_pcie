defmodule ExPcie.Dma.Ref do
  @moduledoc """
  Reference model of the DMA channels' observable behaviour, in plain
  Elixir and independent of timing: which TLPs a channel emits for a given
  configuration and stream, and what ends up in (or comes out of) the
  ring. The RTL is checked against these in the tests.

  Options (`base`, `ring`, `period` in bytes; `mps` and `mrrs` in bytes):

    * C2H segmentation: a TLP covers whole 32-byte beats and ends at
      `tlast`, at `mps` bytes, before a 4 KiB boundary or at the end of
      a period, whichever comes first.
    * H2C requests: consecutive reads of the ring, each at most one slot
      (256 bytes) and `mrrs`, ending at a 4 KiB boundary or the end of
      the ring.
  """

  @beat 32
  @slot 256

  @doc """
  Write TLPs `[{address, bytes}]` for a stream whose beats carry the given
  `tlast` flags (booleans).
  """
  def c2h_segments(lasts, opts) do
    base = Keyword.fetch!(opts, :base)
    ring = Keyword.fetch!(opts, :ring)
    period = Keyword.fetch!(opts, :period)
    mps = Keyword.get(opts, :mps, 128)

    {segs, _} =
      Enum.reduce(lasts, {[], %{off: 0, pleft: period, start: 0, n: 0}}, fn last, {acc, st} ->
        addr = base + st.off
        room = Enum.min([mps - st.n * @beat, 4096 - rem(addr, 4096), st.pleft])
        n = st.n + 1
        start = if st.n == 0, do: st.off, else: st.start
        off = rem(st.off + @beat, ring)
        pleft = if st.pleft == @beat, do: period, else: st.pleft - @beat

        if last or room <= @beat,
          do: {[{base + start, n * @beat} | acc], %{off: off, pleft: pleft, start: 0, n: 0}},
          else: {acc, %{off: off, pleft: pleft, start: start, n: n}}
      end)

    Enum.reverse(segs)
  end

  @doc "The bytes of a stream of beats (`tdata` integers), 32 bytes each, little-endian."
  def stream_bytes(beats), do: for(b <- beats, into: <<>>, do: <<b::little-256>>)

  @doc "Ring contents after `stream` (a binary) was written from offset 0 in a loop; unwritten bytes are zero."
  def c2h_ring(stream, ring) do
    total = byte_size(stream)
    rest = rem(total, ring)

    if total < ring do
      stream <> :binary.copy(<<0>>, ring - total)
    else
      binary_part(stream, total - rest, rest) <>
        binary_part(stream, total - ring, ring - rest)
    end
  end

  @doc "The first `n` read requests `[{address, bytes}]` of an H2C channel."
  def h2c_requests(n, opts) do
    base = Keyword.fetch!(opts, :base)
    ring = Keyword.fetch!(opts, :ring)
    mrrs = Keyword.get(opts, :mrrs, 512)
    limit = min(@slot, mrrs)

    {reqs, _} =
      Enum.map_reduce(1..n//1, 0, fn _, off ->
        addr = base + off
        len = Enum.min([limit, 4096 - rem(addr, 4096), ring - off])
        {{addr, len}, rem(off + len, ring)}
      end)

    reqs
  end

  @doc "The first `bytes` bytes the H2C stream delivers for ring contents `data`."
  def h2c_stream(data, bytes) do
    reps = div(bytes + byte_size(data) - 1, byte_size(data))
    binary_part(:binary.copy(data, reps), 0, bytes)
  end
end
