defmodule ExPcie.DRing do
  @moduledoc """
  Descriptor ring format shared by the hardware (`ExPcie.RTL.DescRing`)
  and the host side (`ExPcie.Model.Driver`, drivers for a real card).

  A ring is an array of `dsize` descriptors of 32 bytes in host memory at
  `dbase` (32-byte aligned), one ring per channel. The host fills
  descriptors and writes the index after the last one to the doorbell
  register (`h2c_dhead`, `c2h_dhead`); indices run from 0 to `dsize - 1`
  and wrap, at most `dsize - 1` descriptors may be posted. The card
  fetches in order and completes in order.

  Descriptor, little-endian DWords:

  | DWord | Written by | Content |
  |---|---|---|
  | 0 | host | buffer address, bits 31:0 (32-byte aligned) |
  | 1 | host | buffer address, bits 63:32 |
  | 2 | host | buffer length in bytes, bits 27:0, a multiple of 32, not 0 |
  | 3 | host | flags: bit 0 `irq` interrupt when complete, bit 1 `stop` (C2H) the descriptor also ends at the end of a stream packet |
  | 4, 5 | host | free for software (a cookie), not touched by the card |
  | 6 | card | status: bit 0 `done`, bit 1 `error`, bit 2 `eop` |
  | 7 | card | bytes transferred |

  H2C: the card reads `length` bytes at `address` and streams them out;
  `error` is set when a read completion failed or timed out (the stream
  then carries whatever the slot held). C2H: the card writes stream data
  into the buffer; the descriptor completes when the buffer is full, or,
  with the `stop` flag, at the end of a stream packet (`tlast`), then
  `eop` is set and DWord 7 holds the bytes written. Without descriptors
  the stream is back-pressured.

  Write-back (`dctrl` register): with `wb_desc` the card writes DWords 6
  and 7 of each completed descriptor (a single 8-byte posted write);
  with `wb_head` it writes 8 bytes to the write-back address after that:
  DWord 0 the tail index (the next descriptor to complete), DWord 1 the
  number of descriptors completed so far (free running, 32 bits). The host
  polls DWord 1 or the `done` bit, or waits for the interrupt (vector 0
  for H2C, 1 for C2H) that follows the write-back when the descriptor had
  the `irq` flag and `dctrl.irq_en` is set. A host that reuses a
  descriptor clears DWord 6 first.

  Setup order: `dbase`, `dsize`, `wb`, `dctrl`, `ctrl` with the `desc`
  bit and the run bit, then post descriptors and ring the doorbell
  (it may be done before the run bit). Clearing the run bit resets the
  ring (indices restart at 0).
  """
  import Bitwise

  @flag_irq 1
  @flag_stop 2

  def flag_irq, do: @flag_irq
  def flag_stop, do: @flag_stop
  def size, do: 32

  @doc "The 32-byte descriptor. `flags` is an integer or a list of `:irq`, `:stop`; `cookie` fills DWords 4 and 5."
  def encode(addr, len, flags \\ 0, cookie \\ 0) do
    <<addr::little-64, len::little-32, flags(flags)::little-32, cookie::little-64, 0::64>>
  end

  @doc "Decodes a descriptor binary into a map (status fields as written by the card)."
  def decode(
        <<addr::little-64, len::little-32, fl::little-32, cookie::little-64, st::little-32,
          n::little-32>>
      ) do
    %{
      addr: addr,
      len: len,
      irq: (fl &&& @flag_irq) != 0,
      stop: (fl &&& @flag_stop) != 0,
      cookie: cookie,
      done: (st &&& 1) != 0,
      error: (st &&& 2) != 0,
      eop: (st &&& 4) != 0,
      bytes: n
    }
  end

  @doc "The head write-back block: `%{tail: index, count: completed}`."
  def decode_head(<<tail::little-32, count::little-32>>), do: %{tail: tail, count: count}

  defp flags(n) when is_integer(n), do: n

  defp flags(list) when is_list(list),
    do:
      Enum.reduce(list, 0, fn
        :irq, a -> a ||| @flag_irq
        :stop, a -> a ||| @flag_stop
      end)
end
