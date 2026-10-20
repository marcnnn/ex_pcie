defmodule ExPcie.Model.HostMem do
  @moduledoc """
  Sparse byte-addressable host memory for the BEAM models: 4 KiB pages in
  a map, unwritten bytes read as zero.
  """
  import Bitwise

  @page 4096

  def new, do: %{}

  @doc "Writes `bin` at byte address `addr` (may span pages)."
  def write(mem, _addr, <<>>), do: mem

  def write(mem, addr, bin) do
    pn = addr >>> 12
    off = addr &&& 0xFFF
    n = min(byte_size(bin), @page - off)
    <<chunk::binary-size(n), rest::binary>> = bin
    page = Map.get(mem, pn, <<0::size(@page * 8)>>)
    <<a::binary-size(off), _::binary-size(n), b::binary>> = page
    write(Map.put(mem, pn, <<a::binary, chunk::binary, b::binary>>), addr + n, rest)
  end

  @doc "Reads `len` bytes at `addr`."
  def read(mem, addr, len), do: read(mem, addr, len, <<>>)

  defp read(_mem, _addr, 0, acc), do: acc

  defp read(mem, addr, len, acc) do
    off = addr &&& 0xFFF
    n = min(len, @page - off)
    page = Map.get(mem, addr >>> 12, <<0::size(@page * 8)>>)
    read(mem, addr + n, len - n, <<acc::binary, binary_part(page, off, n)::binary>>)
  end
end
