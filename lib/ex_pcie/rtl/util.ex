defmodule ExPcie.RTL.Util do
  @moduledoc """
  Hardware helpers shared by the RTL modules: PCIe descriptors as `cat`
  and slices of `tdata`, DWord lanes, byte-enable arithmetic. Everything
  here builds `ExHdl.RTL.Expr` values and must be called while a module
  is being elaborated.
  """
  use ExHdl.RTL
  import Bitwise, only: [>>>: 2, <<<: 2]

  alias ExPcie.Desc
  alias ExHdl.RTL.Expr

  @doc """
  The descriptor of `kind` as one expression (96 or 128 bits). `fields`
  maps field names (`ExPcie.Desc.fields/1`) to expressions, integers,
  booleans or request type atoms; omitted fields and gaps are zero. The
  `:address` field takes a 64-bit expression (bits 1:0 are ignored) or an
  integer.
  """
  def desc(kind, fields) do
    spec = Desc.fields(kind)

    case Map.keys(fields) -- Keyword.keys(spec) do
      [] -> :ok
      bad -> raise ArgumentError, "unknown #{kind} descriptor fields #{inspect(bad)}"
    end

    total = 32 * Desc.size_dw(kind)

    {parts, pos} =
      spec
      |> Enum.sort_by(fn {_, {lsb, _, _}} -> -lsb end)
      |> Enum.reduce({[], total}, fn {name, {lsb, w, type}}, {acc, pos} ->
        gap = if pos > lsb + w, do: [const(0, pos - lsb - w)], else: []
        {[field_value(type, w, Map.get(fields, name, 0)) | gap] ++ acc, lsb}
      end)

    parts = if pos > 0, do: [const(0, pos) | parts], else: parts
    cat(Enum.reverse(parts))
  end

  defp field_value(:addr, w, v) when is_integer(v), do: const(v >>> 2, w)
  defp field_value(:addr, w, %Expr{} = e), do: slice(e, 2, w)
  defp field_value(:req, w, v) when is_atom(v), do: const(Desc.req_type_code(v), w)
  defp field_value(_, w, v) when is_integer(v), do: const(v, w)
  defp field_value(_, w, v) when is_boolean(v), do: const(if(v, do: 1, else: 0), w)

  defp field_value(_, w, %Expr{} = e) do
    if width(e) > w, do: raise(ArgumentError, "descriptor field wider than #{w} bits")
    if width(e) == w, do: e, else: zext(e, w)
  end

  @doc "Field `name` of a descriptor held in the low bits of `expr` (the address as 64 bits with zero low bits)."
  def field(kind, expr, name) do
    {lsb, w, type} = Keyword.fetch!(Desc.fields(kind), name)
    if type == :addr, do: cat([slice(expr, lsb, w), const(0, 2)]), else: slice(expr, lsb, w)
  end

  @doc "DWord lane `i` (32 bits) of `expr`."
  def lane(expr, i), do: slice(expr, 32 * i, 32)

  @doc "Lanes `lo..hi` as one expression."
  def lanes(expr, lo, hi), do: slice(expr, 32 * lo, 32 * (hi - lo + 1))

  @doc "Unused low bytes (u2) of a 4-bit byte enable."
  def lo_off(be),
    do: mux(be[0], const(0, 2), mux(be[1], const(1, 2), mux(be[2], const(2, 2), const(3, 2))))

  @doc "Unused high bytes (u2) of a 4-bit byte enable."
  def hi_off(be),
    do: mux(be[3], const(0, 2), mux(be[2], const(1, 2), mux(be[1], const(2, 2), const(3, 2))))

  @doc "A `w`-bit mask with the low `n` bits set (n an unsigned expression below 2^width(n))."
  def low_ones(n, w),
    do: mux(n, for(i <- 0..((1 <<< width(n)) - 1), do: const((1 <<< min(i, w)) - 1, w)))

  @doc "`ceil(log2(n))`, at least 1."
  def clog2(n), do: max(ExHdl.RTL.Builder.ceil_log2(n), 1)
end
