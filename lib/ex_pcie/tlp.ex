defmodule ExPcie.TLP do
  @moduledoc """
  PCIe transaction layer packets as plain structs, with a codec for the
  wire format (big-endian header DWords followed by payload bytes in
  address order). Covers memory read and write requests and completions
  (`Cpl`, `CplD`), the packets the BAR bridge and the DMA engine exchange
  with the host.

      tlp = %ExPcie.TLP{kind: :mwr, address: 0x1_0000_1000, tag: 0, data: <<1, 2, 3, 4>>}
      tlp |> ExPcie.TLP.encode() |> ExPcie.TLP.decode()

  Fields: `tc`, `attr` (3 bits, `{IDO, RO, NS}` from bit 2 down), `td`,
  `ep`, `requester_id`, `tag`. Requests add `address` (byte address, bits
  1:0 are zero), `first_be`, `last_be`, `data`; the length comes from
  `data` (writes) or `length_dw` (reads). Completions add `completer_id`,
  `status`, `bcm`, `byte_count`, `lower_address`, `data`.

  Memory requests use the 3 DW header below 4 GiB and the 4 DW header at
  or above, as the specification requires. A length of 1024 DW is encoded
  as 0. Not modelled: prefixes, digests, address translation.
  """
  import Bitwise

  defstruct kind: :mwr,
            tc: 0,
            attr: 0,
            td: false,
            ep: false,
            requester_id: 0,
            tag: 0,
            address: 0,
            length_dw: nil,
            first_be: 0xF,
            last_be: nil,
            completer_id: 0,
            status: 0,
            bcm: false,
            byte_count: nil,
            lower_address: 0,
            data: <<>>

  @type t :: %__MODULE__{}

  @status %{sc: 0, ur: 1, crs: 2, ca: 4}

  @doc "Completion status code (`:sc`, `:ur`, `:crs`, `:ca`)."
  def status(name), do: Map.fetch!(@status, name)

  @doc "Length of the payload or read in DWords."
  def length_dw(%__MODULE__{data: data, length_dw: nil}), do: div(byte_size(data), 4)
  def length_dw(%__MODULE__{length_dw: n}), do: n

  @doc """
  Byte count of the first completion of a read request: bytes from the
  lowest enabled byte of the first DW to the highest enabled byte of the
  last DW. `last_be` is ignored for single-DW requests.
  """
  def request_byte_count(length_dw, first_be, last_be) do
    cond do
      length_dw == 1 and first_be == 0 -> 1
      length_dw == 1 -> max(4 - lo_off(first_be) - hi_off(first_be), 1)
      true -> 4 * length_dw - lo_off(first_be) - hi_off(last_be)
    end
  end

  @doc "Number of unused low bytes of a byte enable nibble."
  def lo_off(be), do: Enum.find(0..3, 3, &((be >>> &1 &&& 1) == 1))

  @doc "Number of unused high bytes of a byte enable nibble."
  def hi_off(be), do: Enum.find(0..3, 3, &((be >>> (3 - &1) &&& 1) == 1))

  @doc """
  Lower address field (7 bits) of the first completion for a request at
  `address` with byte enable `first_be`.
  """
  def lower_address(address, first_be), do: (address &&& 0x7C) ||| lo_off(first_be)

  @doc """
  Legal completion chunking of a read of `len` bytes at `address`:
  `[{address, bytes}]`, split only at multiples of `rcb` (64 or 128) and
  with chunks of at most `mps` bytes. `cuts:` picks which of the optional
  RCB boundaries become splits: `:all` (default), `:none`, or a function
  `fn boundary_address -> boolean`.
  """
  def completion_chunks(address, len, rcb, mps, cuts \\ :all) do
    stop = address + len
    cut? = cut_fun(cuts)

    boundaries =
      Stream.iterate(div(address, rcb) * rcb + rcb, &(&1 + rcb))
      |> Enum.take_while(&(&1 < stop))

    {chunks, start} =
      Enum.reduce(boundaries, {[], address}, fn b, {acc, start} ->
        if cut?.(b) or b - start + rcb > mps,
          do: {[{start, b - start} | acc], b},
          else: {acc, start}
      end)

    Enum.reverse([{start, stop - start} | chunks])
  end

  defp cut_fun(:all), do: fn _ -> true end
  defp cut_fun(:none), do: fn _ -> false end
  defp cut_fun(f) when is_function(f, 1), do: f

  # -- encoding --------------------------------------------------------------------------

  @doc "Encodes a TLP to its wire bytes."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{kind: kind} = t) when kind in [:mrd, :mwr] do
    len = length_dw(t)
    data? = kind == :mwr
    four? = t.address >= 1 <<< 32
    fmt = if(data?, do: 2, else: 0) + if four?, do: 1, else: 0
    last_be = t.last_be || if len == 1, do: 0, else: 0xF

    if data? and byte_size(t.data) != len * 4,
      do: raise(ArgumentError, "write payload is #{byte_size(t.data)} bytes, length is #{len} DW")

    if len < 1 or len > 1024, do: raise(ArgumentError, "length #{len} DW out of range")
    if (t.address &&& 3) != 0, do: raise(ArgumentError, "address must be DWord aligned")

    dw1 = t.requester_id <<< 16 ||| t.tag <<< 8 ||| last_be <<< 4 ||| t.first_be

    addr =
      if four?,
        do: <<t.address >>> 32::32, t.address &&& 0xFFFF_FFFC::32>>,
        else: <<t.address::32>>

    <<header(fmt, 0, t, len)::32, dw1::32, addr::binary, t.data::binary>>
  end

  def encode(%__MODULE__{kind: kind} = t) when kind in [:cpl, :cpld] do
    data? = kind == :cpld
    len = if data?, do: length_dw(t), else: 0
    bc = t.byte_count || 4

    dw1 =
      t.completer_id <<< 16 ||| t.status <<< 13 ||| bit(t.bcm) <<< 12 ||| (bc &&& 0xFFF)

    dw2 = t.requester_id <<< 16 ||| t.tag <<< 8 ||| (t.lower_address &&& 0x7F)

    <<header(if(data?, do: 2, else: 0), 0b01010, t, len)::32, dw1::32, dw2::32, t.data::binary>>
  end

  defp header(fmt, type, t, len) do
    fmt <<< 29 ||| type <<< 24 ||| t.tc <<< 20 ||| (t.attr >>> 2 &&& 1) <<< 18 |||
      bit(t.td) <<< 15 ||| bit(t.ep) <<< 14 ||| (t.attr &&& 3) <<< 12 ||| (len &&& 0x3FF)
  end

  defp bit(true), do: 1
  defp bit(false), do: 0

  # -- decoding --------------------------------------------------------------------------

  @doc "Decodes wire bytes. Returns `{:ok, tlp}` or `{:error, reason}`."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(<<dw0::32, rest::binary>> = bin) when byte_size(bin) >= 12 do
    fmt = dw0 >>> 29
    type = dw0 >>> 24 &&& 0x1F
    len = if (dw0 &&& 0x3FF) == 0, do: 1024, else: dw0 &&& 0x3FF
    base = %__MODULE__{tc: dw0 >>> 20 &&& 7, td: bit?(dw0, 15), ep: bit?(dw0, 14)}
    base = %{base | attr: (dw0 >>> 18 &&& 1) <<< 2 ||| (dw0 >>> 12 &&& 3)}

    case {fmt, type} do
      {f, 0} when f in 0..3 -> memory(base, f, len, rest)
      {f, 0b01010} when f in [0, 2] -> completion(base, f, len, rest)
      _ -> {:error, {:unsupported, fmt, type}}
    end
  end

  def decode(_), do: {:error, :short}

  defp bit?(v, n), do: (v >>> n &&& 1) == 1

  defp memory(base, fmt, len, rest) do
    four? = (fmt &&& 1) == 1
    data? = (fmt &&& 2) == 2
    alen = if four?, do: 8, else: 4

    with <<dw1::32, addr::binary-size(alen), data::binary>> <- rest do
      address =
        case addr do
          <<hi::32, lo::32>> -> hi <<< 32 ||| lo
          <<a::32>> -> a
        end

      if data? and byte_size(data) != len * 4 do
        {:error, {:payload_length, byte_size(data), len}}
      else
        {:ok,
         %{
           base
           | kind: if(data?, do: :mwr, else: :mrd),
             requester_id: dw1 >>> 16,
             tag: dw1 >>> 8 &&& 0xFF,
             last_be: dw1 >>> 4 &&& 0xF,
             first_be: dw1 &&& 0xF,
             address: address &&& 0xFFFF_FFFF_FFFF_FFFC,
             length_dw: len,
             data: if(data?, do: data, else: <<>>)
         }}
      end
    else
      _ -> {:error, :short}
    end
  end

  defp completion(base, fmt, len, <<dw1::32, dw2::32, data::binary>>) do
    data? = fmt == 2

    if data? and byte_size(data) != len * 4 do
      {:error, {:payload_length, byte_size(data), len}}
    else
      bc = dw1 &&& 0xFFF

      {:ok,
       %{
         base
         | kind: if(data?, do: :cpld, else: :cpl),
           completer_id: dw1 >>> 16,
           status: dw1 >>> 13 &&& 7,
           bcm: bit?(dw1, 12),
           byte_count: if(bc == 0, do: 4096, else: bc),
           requester_id: dw2 >>> 16,
           tag: dw2 >>> 8 &&& 0xFF,
           lower_address: dw2 &&& 0x7F,
           length_dw: if(data?, do: len, else: 0),
           data: data
       }}
    end
  end
end
