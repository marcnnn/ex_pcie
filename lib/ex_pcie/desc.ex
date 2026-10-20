defmodule ExPcie.Desc do
  @moduledoc """
  Request and completion descriptors of the UltraScale+ PCIE4C AXI4-Stream
  interfaces (Xilinx PG213), as integers of 128 (CQ, RQ) or 96 bits (CC,
  RC). The descriptor occupies the first DWords of the first beat, bit 0
  of the integer being bit 0 of `tdata`.

  | Kind | Direction | Bits | Notes |
  |---|---|---|---|
  | `:cq` | core to user | 128 | completer request (host MMIO and the like) |
  | `:cc` | user to core | 96 | completer completion |
  | `:rq` | user to core | 128 | requester request (DMA reads, writes) |
  | `:rc` | core to user | 96 | requester completion |

  Decoded descriptors are maps keyed by the field names in `fields/1`.
  Booleans are `true`/`false`; `address` is the byte address with bits 1:0
  zero (the AT field takes those bits in the descriptor); `req_type` is an
  atom when known (`:mem_read`, `:mem_write`, `:io_read`, `:io_write`,
  `:fetch_add`, `:swap`, `:cas`, `:locked_read`, `:msg`, `:vendor_msg`),
  else the raw 4-bit code.

  The layouts are written from memory of PG213 (tables "Requester
  Request Descriptor Format" and its three siblings); see
  `ExPcie.Axis` for the list of points to check against the guide.
  """
  import Bitwise

  @req_types [
    mem_read: 0,
    mem_write: 1,
    io_read: 2,
    io_write: 3,
    fetch_add: 4,
    swap: 5,
    cas: 6,
    locked_read: 7,
    msg: 8,
    vendor_msg: 9
  ]

  # {name, lsb, width, type}
  @fields %{
    cq: [
      at: {0, 2, :int},
      address: {2, 62, :addr},
      dw_count: {64, 11, :int},
      req_type: {75, 4, :req},
      poisoned: {79, 1, :bool},
      requester_id: {80, 16, :int},
      tag: {96, 8, :int},
      target_function: {104, 8, :int},
      bar_id: {112, 3, :int},
      bar_aperture: {115, 6, :int},
      tc: {121, 3, :int},
      attr: {124, 3, :int}
    ],
    cc: [
      lower_address: {0, 7, :int},
      at: {8, 2, :int},
      byte_count: {16, 13, :int},
      locked: {29, 1, :bool},
      dw_count: {32, 11, :int},
      status: {43, 3, :int},
      poisoned: {46, 1, :bool},
      requester_id: {48, 16, :int},
      tag: {64, 8, :int},
      completer_id: {72, 16, :int},
      completer_id_enable: {88, 1, :bool},
      tc: {89, 3, :int},
      attr: {92, 3, :int},
      force_ecrc: {95, 1, :bool}
    ],
    rq: [
      at: {0, 2, :int},
      address: {2, 62, :addr},
      dw_count: {64, 11, :int},
      req_type: {75, 4, :req},
      poisoned: {79, 1, :bool},
      requester_id: {80, 16, :int},
      tag: {96, 8, :int},
      completer_id: {104, 16, :int},
      requester_id_enable: {120, 1, :bool},
      tc: {121, 3, :int},
      attr: {124, 3, :int},
      force_ecrc: {127, 1, :bool}
    ],
    rc: [
      lower_address: {0, 12, :int},
      error_code: {12, 4, :int},
      byte_count: {16, 13, :int},
      locked: {29, 1, :bool},
      request_completed: {30, 1, :bool},
      dw_count: {32, 11, :int},
      status: {43, 3, :int},
      poisoned: {46, 1, :bool},
      requester_id: {48, 16, :int},
      tag: {64, 8, :int},
      completer_id: {72, 16, :int},
      tc: {89, 3, :int},
      attr: {92, 3, :int}
    ]
  }

  @doc "Descriptor size in DWords: 4 for `:cq` and `:rq`, 3 for `:cc` and `:rc`."
  def size_dw(kind) when kind in [:cq, :rq], do: 4
  def size_dw(kind) when kind in [:cc, :rc], do: 3

  @doc "Field names with `{lsb, width, type}` of a descriptor kind."
  def fields(kind), do: Map.fetch!(@fields, kind)

  @doc "4-bit request type code of an atom (integers pass through)."
  def req_type_code(c) when is_integer(c), do: c
  def req_type_code(name), do: Keyword.fetch!(@req_types, name)

  @doc "Encodes a map of fields; missing fields are zero, unknown keys raise."
  def encode(kind, map) do
    fs = fields(kind)

    case Map.keys(map) -- Keyword.keys(fs) do
      [] -> :ok
      bad -> raise ArgumentError, "unknown #{kind} descriptor fields #{inspect(bad)}"
    end

    Enum.reduce(fs, 0, fn {name, {lsb, w, type}}, acc ->
      v = Map.get(map, name, 0)
      raw = raw(type, v)

      if raw >>> w != 0 or raw < 0,
        do: raise(ArgumentError, "#{kind}.#{name} = #{inspect(v)} does not fit #{w} bits")

      acc ||| raw <<< lsb
    end)
  end

  defp raw(:int, v) when is_integer(v), do: v
  defp raw(:bool, v) when v in [true, 1], do: 1
  defp raw(:bool, v) when v in [false, 0], do: 0
  defp raw(:req, v), do: req_type_code(v)

  defp raw(:addr, v) do
    if (v &&& 3) != 0, do: raise(ArgumentError, "address #{v} is not DWord aligned")
    v >>> 2
  end

  @doc "Decodes an integer into a map with every field."
  def decode(kind, int) do
    Map.new(fields(kind), fn {name, {lsb, w, type}} ->
      raw = int >>> lsb &&& (1 <<< w) - 1

      v =
        case type do
          :int -> raw
          :bool -> raw == 1
          :addr -> raw <<< 2
          :req -> Enum.find_value(@req_types, raw, fn {n, c} -> if c == raw, do: n end)
        end

      {name, v}
    end)
  end
end
