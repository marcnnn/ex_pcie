defmodule ExPcie.Regs do
  @moduledoc """
  BAR0 register map of `ExPcie.RTL.Endpoint`, declared once with
  `ExHdl.Regs`: the AXI4-Lite slave (`rtl/1`), host helpers (`offset/1`,
  `encode/2`, `decode/2`), a C header and Markdown (`c_header/1`,
  `markdown/1`). `ExPcie.Host` reads its offsets from here.

  The layout is unchanged from the hand-written register file this
  replaced; 16 KiB at BAR0 offset 0, byte offsets:

  | Offset | Register | Fields |
  |---|---|---|
  | 0x000 | `id` | `value` `0x50434945` (ro) |
  | 0x004 | `caps` | `vectors` [7:0], `stream_bytes` [15:8] (ro) |
  | 0x010 | `ctrl` | `h2c_run` [0], `c2h_run` [1] (rw) |
  | 0x014 | `status` | `h2c_period` [0], `c2h_period` [1], `h2c_error` [2] (w1c) |
  | 0x020 | `h2c_base_lo`, `h2c_base_hi`, `h2c_ring`, `h2c_period` | `value` (rw) |
  | 0x030 | `h2c_ptr`, `h2c_err` | `value` (ro) |
  | 0x040 | `c2h_base_lo`, `c2h_base_hi`, `c2h_ring`, `c2h_period` | `value` (rw) |
  | 0x050 | `c2h_ptr`, `c2h_pkt` | `value` (ro) |
  | 0x060 | `irq_force` | `vec` (wo, strobe: a write raises the vectors in the written bits) |
  | 0x064 | `irq_pending` | `value` (ro) |
  | 0x068 | `bridge_err` | `ur` [15:0], `dropped` [31:16] (ro) |
  | 0x06C | `axil_err` | `value` (ro) |
  | 0x1000 + 16 i | `msix<i>_lo`, `msix<i>_hi`, `msix<i>_data` | `value` (rw) |
  | 0x100C + 16 i | `msix<i>_ctrl` | `mask` [0] (rw, reset 1) |
  | 0x2000 | `pba` | `value` (ro) |

  What changed against the stand-in: the read of `caps` and `id` need no
  hardware input (constants), the `ctrl` and `status` bits are named
  fields (`ctrl_h2c_run`, `status_h2c_error_set`), `irq_force` is a
  write-only field with a write strobe, and reads of holes (and writes to
  them) answer SLVERR as before. A register read returns 1 cycle after
  the address handshake, as before.
  """
  use ExHdl.Regs

  @id 0x50434945

  @doc "The register map for `vectors` MSI-X vectors (2 to 32, default 2)."
  @spec map(pos_integer()) :: ExHdl.Regs.t()
  def map(vectors \\ 2) do
    unless vectors in 1..32, do: raise(ArgumentError, "vectors must be 1..32")

    regmap "pcie_endpoint_regs_#{vectors}", addr_width: 14, doc: "PCIe endpoint BAR0" do
      register :id, offset: 0x000, doc: "Identification" do
        field :value, 0..31, :ro, const: @id
      end

      register :caps, offset: 0x004, doc: "Capabilities" do
        field :vectors, 0..7, :ro, const: vectors, doc: "MSI-X vectors"
        field :stream_bytes, 8..15, :ro, const: 32, doc: "User stream bytes per beat"
      end

      register :ctrl, offset: 0x010, doc: "Channel run bits" do
        field :h2c_run, 0, :rw, doc: "Host to card channel runs"
        field :c2h_run, 1, :rw, doc: "Card to host channel runs"
      end

      register :status, offset: 0x014, doc: "Sticky status, write 1 to clear" do
        field :h2c_period, 0, :w1c, doc: "H2C period delivered"
        field :c2h_period, 1, :w1c, doc: "C2H period written"
        field :h2c_error, 2, :w1c, doc: "H2C completion error seen"
      end

      for {ch, base} <- [h2c: 0x020, c2h: 0x040] do
        for {n, off} <- [base_lo: 0, base_hi: 4, ring: 8, period: 12] do
          register :"#{ch}_#{n}", offset: base + off do
            field :value, 0..31, :rw
          end
        end
      end

      register :h2c_ptr, offset: 0x030, doc: "H2C bytes delivered, modulo ring" do
        field :value, 0..31, :ro
      end

      register :h2c_err, offset: 0x034, doc: "H2C completion errors" do
        field :value, 0..31, :ro
      end

      register :c2h_ptr, offset: 0x050, doc: "C2H bytes written, modulo ring" do
        field :value, 0..31, :ro
      end

      register :c2h_pkt, offset: 0x054, doc: "C2H TLPs written" do
        field :value, 0..31, :ro
      end

      register :irq_force, offset: 0x060, strobe: :write, doc: "Raise interrupt vectors" do
        field :vec, 0..(vectors - 1), :wo
      end

      register :irq_pending, offset: 0x064, doc: "Pending interrupt vectors" do
        field :value, 0..31, :ro
      end

      register :bridge_err, offset: 0x068, doc: "BAR0 bridge error counters" do
        field :ur, 0..15, :ro, doc: "Unsupported request completions"
        field :dropped, 16..31, :ro, doc: "Dropped posted requests"
      end

      register :axil_err, offset: 0x06C, doc: "AXI4-Lite error responses seen" do
        field :value, 0..31, :ro
      end

      for i <- 0..(vectors - 1) do
        base = 0x1000 + 16 * i

        for {n, off} <- [lo: 0, hi: 4, data: 8] do
          register :"msix#{i}_#{n}", offset: base + off do
            field :value, 0..31, :rw
          end
        end

        register :"msix#{i}_ctrl", offset: base + 12 do
          field :mask, 0, :rw, reset: 1, doc: "Vector masked"
        end
      end

      register :pba, offset: 0x2000, doc: "MSI-X pending bit array" do
        field :value, 0..31, :ro
      end
    end
  end

  @doc "Byte offset of register `name` (`map/1` with 32 vectors covers every name)."
  def offset(name), do: ExHdl.Regs.offset(map(32), name)

  @doc "Register word from field values."
  def encode(name, fields), do: ExHdl.Regs.encode(map(32), name, fields)

  @doc "Field values of a register word."
  def decode(name, word), do: ExHdl.Regs.decode(map(32), name, word)

  @doc "The AXI4-Lite slave of `map/1` (holes answer SLVERR)."
  def rtl(vectors \\ 2), do: ExHdl.Regs.RTL.build(map(vectors), unmapped: :slverr)

  @doc "C header text of `map/1`."
  def c_header(vectors \\ 2), do: ExHdl.Regs.CHeader.render(map(vectors))

  @doc "Markdown table of `map/1`."
  def markdown(vectors \\ 2), do: ExHdl.Regs.Markdown.render(map(vectors))
end
