defmodule ExPcie.Axis do
  @moduledoc """
  The PCIE4C user streams (CQ, CC, RQ, RC) as lists of beats, and the
  conversion between those and `ExPcie.TLP`.

  A beat is `%{data: integer, keep: integer, last: boolean, user: integer}`
  with `dw` bits of `data` (default 256), `keep` one bit per DWord, and
  `user` the sideband of the kind (`user_width/1`). A packet is the
  descriptor (`ExPcie.Desc`) followed directly by the payload DWords;
  payload bytes are little-endian in `data` (the byte at the lowest
  address is bits 7:0). This is the DWord-aligned mode: the payload
  starts in the lane right after the descriptor, not at an address
  dependent lane.

  ## Written from memory of PG213, to be checked

    * Sideband (`tuser`) widths for 256-bit data: CQ 88, CC 33, RQ 62,
      RC 75, and the bit positions in `user/2`. Only `first_be`,
      `last_be`, `discontinue` and `byte_en` are used by the RTL here;
      parity, TPH, sequence number and the straddle bits (`is_sof`,
      `is_eof`) are written as zero or as documented below but ignored.
    * Descriptor layouts (`ExPcie.Desc`), notably RC `error_code` values
      (0 is normal completion, anything else is an error here) and the
      CC `dw_count` of 0 for completions without data.
    * `tkeep` is DWord granular on all four interfaces.
    * No RC straddling at 256 bits, one TLP at a time per beat sequence.
    * The core fills in the requester ID of RQ packets (the
      `requester_id_enable` bit is 0) and the completer ID of CC packets.
    * Tag management is done by the user logic (the descriptor tag is
      used as is), not by the core.
  """
  import Bitwise
  alias ExPcie.{Desc, TLP}

  @type beat :: %{
          data: non_neg_integer(),
          keep: non_neg_integer(),
          last: boolean(),
          user: integer()
        }

  @user_width %{cq: 88, cc: 33, rq: 62, rc: 75}

  @doc "Sideband width in bits of a stream kind (256-bit data)."
  def user_width(kind), do: Map.fetch!(@user_width, kind)

  @doc """
  Sideband integer from named fields.

    * `:cq`: `first_be` 3:0, `last_be` 7:4, `byte_en` 39:8, `sop` 40,
      `discontinue` 41
    * `:cc`: `discontinue` 0
    * `:rq`: `first_be` 3:0, `last_be` 7:4, `addr_offset` 10:8,
      `discontinue` 11
    * `:rc`: `byte_en` 31:0, `is_sof_0` 32, `is_eof_0` 37:34 (bit 3
      valid, bits 2:0 last DWord lane), `discontinue` 42
  """
  def user(kind, fields) do
    Enum.reduce(fields, 0, fn {k, v}, acc ->
      {lsb, w} = user_field(kind, k)
      v = if is_boolean(v), do: if(v, do: 1, else: 0), else: v
      if v >>> w != 0, do: raise(ArgumentError, "#{kind} user #{k}=#{v} too wide")
      acc ||| v <<< lsb
    end)
  end

  @doc "Named fields of a sideband integer (inverse of `user/2`)."
  def user_fields(kind, int) do
    for {k, {lsb, w}} <- user_layout(kind), into: %{}, do: {k, int >>> lsb &&& (1 <<< w) - 1}
  end

  defp user_field(kind, k),
    do: Keyword.get(user_layout(kind), k) || raise(ArgumentError, "no #{kind} user field #{k}")

  defp user_layout(:cq),
    do: [first_be: {0, 4}, last_be: {4, 4}, byte_en: {8, 32}, sop: {40, 1}, discontinue: {41, 1}]

  defp user_layout(:cc), do: [discontinue: {0, 1}]

  defp user_layout(:rq),
    do: [first_be: {0, 4}, last_be: {4, 4}, addr_offset: {8, 3}, discontinue: {11, 1}]

  defp user_layout(:rc),
    do: [byte_en: {0, 32}, is_sof_0: {32, 1}, is_eof_0: {34, 4}, discontinue: {42, 1}]

  # -- beat packing ----------------------------------------------------------------------

  @doc """
  Packs a descriptor integer and a payload binary (length a multiple of 4)
  into beats. `first_user` is the sideband of the first beat as fields
  (`user/2`); for `:rc` the byte enables and eof marker are derived.
  """
  @spec pack(atom(), non_neg_integer(), binary(), map() | keyword(), keyword()) :: [beat()]
  def pack(kind, desc, payload, first_user \\ %{}, opts \\ []) do
    d = div(Keyword.get(opts, :dw, 256), 32)
    n = Desc.size_dw(kind)
    dws = for i <- 0..(n - 1), do: desc >>> (32 * i) &&& 0xFFFFFFFF
    pay = for <<w::little-32 <- payload>>, do: w
    chunks = Enum.chunk_every(dws ++ pay, d)
    count = length(chunks)

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {c, i} ->
      keep = (1 <<< length(c)) - 1
      data = c |> Enum.with_index() |> Enum.reduce(0, fn {w, j}, a -> a ||| w <<< (32 * j) end)
      last = i == count - 1

      %{
        data: data,
        keep: keep,
        last: last,
        user: beat_user(kind, i, last, c, n, Map.new(first_user))
      }
    end)
  end

  defp beat_user(kind, 0, _last, _c, _n, first) when kind in [:cq, :rq],
    do: user(kind, if(kind == :cq, do: Map.put_new(first, :sop, 1), else: first))

  defp beat_user(:cc, _, _, _, _, first), do: user(:cc, Map.take(first, [:discontinue]))

  defp beat_user(:rc, i, last, c, n, first) do
    skip = if i == 0, do: n, else: 0
    lanes = length(c)
    be = for l <- skip..(lanes - 1)//1, reduce: 0, do: (acc -> acc ||| 0xF <<< (4 * l))
    eof = if last, do: 8 ||| lanes - 1, else: 0

    user(:rc, %{
      byte_en: be,
      is_sof_0: if(i == 0, do: 1, else: 0),
      is_eof_0: eof,
      discontinue: Map.get(first, :discontinue, 0)
    })
  end

  defp beat_user(_, _, _, _, _, _), do: 0

  @doc """
  Unpacks beats of one packet into `{:ok, desc, payload, first_user}` or
  `{:error, reason}` (non-contiguous or misplaced `keep`, `last` not on the
  final beat, a packet shorter than its descriptor).
  """
  def unpack(kind, beats, opts \\ []) do
    d = div(Keyword.get(opts, :dw, 256), 32)
    n = Desc.size_dw(kind)

    with :ok <- check_beats(beats, d) do
      dws =
        Enum.flat_map(beats, fn b ->
          for j <- 0..(d - 1), (b.keep >>> j &&& 1) == 1, do: b.data >>> (32 * j) &&& 0xFFFFFFFF
        end)

      if length(dws) < n do
        {:error, :short}
      else
        {dd, pay} = Enum.split(dws, n)
        desc = dd |> Enum.with_index() |> Enum.reduce(0, fn {w, i}, a -> a ||| w <<< (32 * i) end)
        {:ok, desc, for(w <- pay, into: <<>>, do: <<w::little-32>>), hd(beats).user}
      end
    end
  end

  defp check_beats([], _), do: {:error, :empty}

  defp check_beats(beats, d) do
    full = (1 <<< d) - 1
    last_i = length(beats) - 1

    beats
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {b, i} ->
      cond do
        b.last != (i == last_i) -> {:error, {:tlast, i}}
        i < last_i and b.keep != full -> {:error, {:keep, i, b.keep}}
        b.keep == 0 or (b.keep &&& b.keep + 1) != 0 -> {:error, {:keep, i, b.keep}}
        true -> nil
      end
    end)
  end

  # -- TLP conversion --------------------------------------------------------------------

  @doc """
  A memory request TLP from the host as CQ beats. Options: `bar_id` (0),
  `bar_aperture` (20, log2 of the BAR size), `target_function` (0), `dw`.
  """
  def cq_beats(%TLP{kind: kind} = t, opts \\ []) when kind in [:mrd, :mwr] do
    len = TLP.length_dw(t)

    desc =
      Desc.encode(:cq, %{
        address: t.address,
        dw_count: len,
        req_type: if(kind == :mrd, do: :mem_read, else: :mem_write),
        poisoned: t.ep,
        requester_id: t.requester_id,
        tag: t.tag,
        target_function: Keyword.get(opts, :target_function, 0),
        bar_id: Keyword.get(opts, :bar_id, 0),
        bar_aperture: Keyword.get(opts, :bar_aperture, 20),
        tc: t.tc,
        attr: t.attr
      })

    pack(:cq, desc, t.data, %{first_be: t.first_be, last_be: t.last_be || 0}, opts)
  end

  @doc "Decodes CC beats into a completion TLP (`:cpl` or `:cpld`), with `completer_id` filled in by the core."
  def cc_to_tlp(beats, completer_id, opts \\ []) do
    with {:ok, desc, payload, _user} <- unpack(:cc, beats, opts) do
      d = Desc.decode(:cc, desc)

      if byte_size(payload) != d.dw_count * 4 do
        {:error, {:payload, byte_size(payload), d.dw_count}}
      else
        {:ok,
         %TLP{
           kind: if(d.dw_count > 0, do: :cpld, else: :cpl),
           tc: d.tc,
           attr: d.attr,
           ep: d.poisoned,
           requester_id: d.requester_id,
           completer_id: completer_id,
           tag: d.tag,
           status: d.status,
           byte_count: d.byte_count,
           lower_address: d.lower_address,
           length_dw: d.dw_count,
           data: payload
         }}
      end
    end
  end

  @doc """
  Decodes RQ beats into a memory request TLP; `requester_id` is what the
  core inserts. Returns `{:ok, tlp, user_fields}` (the sideband of the first
  beat as fields) or `{:error, reason}`.
  """
  def rq_to_tlp(beats, requester_id, opts \\ []) do
    with {:ok, desc, payload, user} <- unpack(:rq, beats, opts) do
      d = Desc.decode(:rq, desc)
      u = user_fields(:rq, user)

      kind =
        case d.req_type do
          :mem_read -> :mrd
          :mem_write -> :mwr
          other -> {:unsupported, other}
        end

      cond do
        is_tuple(kind) ->
          {:error, kind}

        kind == :mwr and byte_size(payload) != d.dw_count * 4 ->
          {:error, {:payload, byte_size(payload), d.dw_count}}

        kind == :mrd and payload != <<>> ->
          {:error, {:payload, byte_size(payload), 0}}

        true ->
          {:ok,
           %TLP{
             kind: kind,
             tc: d.tc,
             attr: d.attr,
             ep: d.poisoned,
             requester_id: requester_id,
             tag: d.tag,
             address: d.address,
             length_dw: d.dw_count,
             first_be: u.first_be,
             last_be: u.last_be,
             data: payload
           }, u}
      end
    end
  end

  @doc """
  A completion TLP from the host as RC beats. `address` is the byte
  address of the first byte in this completion (its low 12 bits form the
  lower address field), `completed` marks the last completion of the
  request. Option `error_code` (0).
  """
  def rc_beats(%TLP{kind: kind} = t, address, completed, opts \\ []) when kind in [:cpl, :cpld] do
    desc =
      Desc.encode(:rc, %{
        lower_address: address &&& 0xFFF,
        error_code: Keyword.get(opts, :error_code, 0),
        byte_count: t.byte_count,
        request_completed: completed,
        dw_count: TLP.length_dw(t),
        status: t.status,
        poisoned: t.ep,
        requester_id: t.requester_id,
        tag: t.tag,
        completer_id: t.completer_id,
        tc: t.tc,
        attr: t.attr
      })

    pack(:rc, desc, t.data, %{}, opts)
  end
end
