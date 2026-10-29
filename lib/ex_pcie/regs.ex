defmodule ExPcie.Regs do
  @moduledoc """
  BAR0 register map of `ExPcie.RTL.Endpoint`, declared once with
  `ExHdl.Regs`: the AXI4-Lite slave (`rtl/1`), host helpers (`offset/1`,
  `encode/2`, `decode/2`), a C header and Markdown (`c_header/1`,
  `markdown/1`). `ExPcie.Host` reads its offsets from here.

  The first part of the layout is unchanged from the hand-written register
  file this replaced; descriptor rings (`ExPcie.DRing`) and the timeout were
  added in free space. 16 KiB at BAR0 offset 0, byte offsets:

  | Offset | Register | Fields |
  |---|---|---|
  | 0x000 | `id` | `value` `0x50434945` (ro) |
  | 0x004 | `caps` | `vectors` [7:0], `stream_bytes` [15:8], `desc` [16] (ro) |
  | 0x010 | `ctrl` | `h2c_run` [0], `c2h_run` [1], `h2c_desc` [2], `c2h_desc` [3] (rw) |
  | 0x018 | `timeout` | `cycles` [23:0] (rw, reset 50000) |
  | 0x014 | `status` | `h2c_period` [0], `c2h_period` [1], `h2c_error` [2] (w1c) |
  | 0x020 | `h2c_base_lo`, `h2c_base_hi`, `h2c_ring`, `h2c_period` | `value` (rw) |
  | 0x030 | `h2c_ptr`, `h2c_err` | `value` (ro) |
  | 0x040 | `c2h_base_lo`, `c2h_base_hi`, `c2h_ring`, `c2h_period` | `value` (rw) |
  | 0x050 | `c2h_ptr`, `c2h_pkt` | `value` (ro) |
  | 0x060 | `irq_force` | `vec` (wo, strobe: a write raises the vectors in the written bits) |
  | 0x064 | `irq_pending` | `value` (ro) |
  | 0x068 | `bridge_err` | `ur` [15:0], `dropped` [31:16] (ro) |
  | 0x06C | `axil_err` | `value` (ro) |
  | 0x100 / 0x140 | `h2c_dbase_lo`, `h2c_dbase_hi`, `h2c_dsize`, `h2c_dhead` | descriptor ring base, entries, doorbell (`c2h_` at 0x140) |
  | 0x110 / 0x150 | `h2c_dtail`, `h2c_dstat` | tail index, `halted` `bad_desc` `fetch_error` (ro) |
  | 0x118 / 0x158 | `h2c_wb_lo`, `h2c_wb_hi`, `h2c_dctrl` (0x120) | write-back address, `wb_desc` `wb_head` `irq_en` (rw) |
  | 0x124 / 0x164 | `h2c_dcount`, `h2c_dfetch` | descriptors completed, next fetch index (ro) |
  | 0x1000 + 16 i | `msix<i>_lo`, `msix<i>_hi`, `msix<i>_data` | `value` (rw) |
  | 0x100C + 16 i | `msix<i>_ctrl` | `mask` [0] (rw, reset 1) |
  | 0x2000 | `pba` | `value` (ro) |

  ## More channel pairs

  With `pairs: n` (2 to 4) pair `p` (1 to `n - 1`) gets a copy of the
  pair-0 channel registers in the free space at `0x200 * p`: every
  channel register of the table above from 0x010 to 0x16F (`ctrl`,
  `status`, the channel registers, the descriptor ring registers) is
  found at `0x200 * p` plus the pair-0 offset, with the pair number
  appended to the channel part of the name:

  | Offset | Register | Fields |
  |---|---|---|
  | 0x200 p + 0x010 | `ctrl<p>` | `h2c_run` [0], `c2h_run` [1], `h2c_desc` [2], `c2h_desc` [3] (rw) |
  | 0x200 p + 0x014 | `status<p>` | `h2c_period` [0], `c2h_period` [1], `h2c_error` [2] (w1c) |
  | 0x200 p + 0x020 | `h2c<p>_base_lo`, `h2c<p>_base_hi`, `h2c<p>_ring`, `h2c<p>_period` | `value` (rw) |
  | 0x200 p + 0x030 | `h2c<p>_ptr`, `h2c<p>_err` | `value` (ro) |
  | 0x200 p + 0x040 | `c2h<p>_base_lo` ... `c2h<p>_period` | `value` (rw) |
  | 0x200 p + 0x050 | `c2h<p>_ptr`, `c2h<p>_pkt` | `value` (ro) |
  | 0x200 p + 0x100 / 0x140 | `h2c<p>_dbase_lo` ... `h2c<p>_dfetch` (and `c2h<p>_`) | as pair 0 |

  The ID, `caps`, `timeout`, `irq_force`, `irq_pending`, the error counters,
  the MSI-X table and the PBA exist once; `timeout` applies to all pairs.
  `pairs` at 0x008 (`count` [3:0], ro) holds the number of pairs; with one
  pair that address is a hole as before.
  MSI-X vector `2 p` is the H2C and `2 p + 1` the C2H interrupt of pair
  `p`, so the map has at least `2 * pairs` vectors. `channel/2` and
  `split_channel/1` convert between a pair number and the channel name
  used in the register names (`:h2c`, `:h2c1`, ...).

  What changed against the stand-in: the read of `caps` and `id` need no
  hardware input (constants), the `ctrl` and `status` bits are named
  fields (`ctrl_h2c_run`, `status_h2c_error_set`), `irq_force` is a
  write-only field with a write strobe, and reads of holes (and writes to
  them) answer SLVERR as before. A register read returns 1 cycle after
  the address handshake, as before.
  """
  use ExHdl.Regs

  @id 0x50434945
  @max_pairs 4
  @pair_stride 0x200

  @doc "Most channel pairs a map can have."
  def max_pairs, do: @max_pairs

  @doc "Byte offset of the register block of channel pair `pair` (0 for pair 0)."
  def pair_base(pair), do: @pair_stride * pair

  @doc "Channel name of `dir` (`:h2c` or `:c2h`) in pair `pair`: `:h2c`, `:h2c1`, `:c2h2`, ..."
  def channel(dir, 0) when dir in [:h2c, :c2h], do: dir
  def channel(dir, pair) when dir in [:h2c, :c2h], do: :"#{dir}#{pair}"

  @doc "`{dir, pair}` of a channel name (inverse of `channel/2`)."
  def split_channel(ch) do
    case Atom.to_string(ch) do
      "h2c" <> n -> {:h2c, pair_num(n)}
      "c2h" <> n -> {:c2h, pair_num(n)}
    end
  end

  defp pair_num(""), do: 0
  defp pair_num(n), do: String.to_integer(n)

  @doc "Name of the `ctrl` or `status` register of a pair (`:ctrl`, `:ctrl1`, ...)."
  def pair_reg(name, 0), do: name
  def pair_reg(name, pair), do: :"#{name}#{pair}"

  @doc """
  The register map for `vectors` MSI-X vectors (1 to 32, default 2) and
  `pairs` channel pairs (1 to 4, default 1; with more than one pair
  `vectors` must be at least `2 * pairs`).
  """
  @spec map(pos_integer(), pos_integer()) :: ExHdl.Regs.t()
  def map(vectors \\ 2, pairs \\ 1) do
    unless vectors in 1..32, do: raise(ArgumentError, "vectors must be 1..32")
    unless pairs in 1..@max_pairs, do: raise(ArgumentError, "pairs must be 1..#{@max_pairs}")

    if pairs > 1 and vectors < 2 * pairs,
      do: raise(ArgumentError, "#{pairs} pairs need at least #{2 * pairs} vectors")

    suffix = if pairs == 1, do: "", else: "_p#{pairs}"

    regmap "pcie_endpoint_regs_#{vectors}#{suffix}", addr_width: 14, doc: "PCIe endpoint BAR0" do
      register :id, offset: 0x000, doc: "Identification" do
        field :value, 0..31, :ro, const: @id
      end

      register :caps, offset: 0x004, doc: "Capabilities" do
        field :vectors, 0..7, :ro, const: vectors, doc: "MSI-X vectors"
        field :stream_bytes, 8..15, :ro, const: 32, doc: "User stream bytes per beat"
        field :desc, 16, :ro, const: 1, doc: "Descriptor rings available"
      end

      if pairs > 1 do
        register :pairs, offset: 0x008, doc: "Channel pairs (a hole with one pair)" do
          field :count, 0..3, :ro, const: pairs, doc: "Channel pairs"
        end
      end

      register :ctrl, offset: 0x010, doc: "Channel run bits" do
        field :h2c_run, 0, :rw, doc: "Host to card channel runs"
        field :c2h_run, 1, :rw, doc: "Card to host channel runs"
        field :h2c_desc, 2, :rw, doc: "H2C uses its descriptor ring (0: simple ring)"
        field :c2h_desc, 3, :rw, doc: "C2H uses its descriptor ring (0: simple ring)"
      end

      register :timeout, offset: 0x018, doc: "Completion timeout" do
        field :cycles, 0..23, :rw,
          reset: 50_000,
          doc: "H2C read completion and descriptor fetch timeout in cycles, 0 disables"
      end

      register :status, offset: 0x014, doc: "Sticky status, write 1 to clear" do
        field :h2c_period, 0, :w1c, doc: "H2C period delivered (descriptor mode: descriptor done)"
        field :c2h_period, 1, :w1c, doc: "C2H period written (descriptor mode: descriptor done)"
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

      for {ch, base} <- [h2c: 0x100, c2h: 0x140] do
        for {n, off, doc} <- [
              {:dbase_lo, 0x00, "Descriptor ring base, low half (32-byte aligned)"},
              {:dbase_hi, 0x04, "Descriptor ring base, high half"},
              {:wb_lo, 0x18, "Head write-back address, low half (8-byte aligned)"},
              {:wb_hi, 0x1C, "Head write-back address, high half"}
            ] do
          register :"#{ch}_#{n}", offset: base + off, doc: doc do
            field :value, 0..31, :rw
          end
        end

        register :"#{ch}_dsize", offset: base + 0x08, doc: "Descriptors in the ring" do
          field :value, 0..15, :rw
        end

        register :"#{ch}_dhead", offset: base + 0x0C, doc: "Doorbell: producer index" do
          field :value, 0..15, :rw
        end

        register :"#{ch}_dtail", offset: base + 0x10, doc: "Next descriptor to complete" do
          field :value, 0..15, :ro
        end

        register :"#{ch}_dstat", offset: base + 0x14, doc: "Descriptor ring status" do
          field :halted, 0, :ro, doc: "Ring halted (cleared by run low)"
          field :bad_desc, 1, :ro, doc: "Misaligned or empty descriptor"
          field :fetch_error, 2, :ro, doc: "Descriptor read failed or timed out"
        end

        register :"#{ch}_dctrl", offset: base + 0x20, doc: "Descriptor ring options" do
          field :wb_desc, 0, :rw, doc: "Write status into the descriptor on completion"
          field :wb_head, 1, :rw, doc: "Write the head block to the write-back address"
          field :irq_en, 2, :rw, doc: "Descriptors with the IRQ flag raise the interrupt"
        end

        register :"#{ch}_dcount", offset: base + 0x24, doc: "Descriptors completed" do
          field :value, 0..31, :ro
        end

        register :"#{ch}_dfetch", offset: base + 0x28, doc: "Next descriptor to fetch" do
          field :value, 0..15, :ro
        end
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

      for p <- 1..(pairs - 1)//1 do
        b = @pair_stride * p
        h = channel(:h2c, p)
        c = channel(:c2h, p)

        register pair_reg(:ctrl, p), offset: b + 0x010, doc: "Channel run bits of pair #{p}" do
          field :h2c_run, 0, :rw, doc: "Host to card channel runs"
          field :c2h_run, 1, :rw, doc: "Card to host channel runs"
          field :h2c_desc, 2, :rw, doc: "H2C uses its descriptor ring (0: simple ring)"
          field :c2h_desc, 3, :rw, doc: "C2H uses its descriptor ring (0: simple ring)"
        end

        register pair_reg(:status, p),
          offset: b + 0x014,
          doc: "Sticky status of pair #{p}, write 1 to clear" do
          field :h2c_period, 0, :w1c,
            doc: "H2C period delivered (descriptor mode: descriptor done)"

          field :c2h_period, 1, :w1c, doc: "C2H period written (descriptor mode: descriptor done)"
          field :h2c_error, 2, :w1c, doc: "H2C completion error seen"
        end

        for {ch, off} <- [{h, 0x020}, {c, 0x040}] do
          for {n, o} <- [base_lo: 0, base_hi: 4, ring: 8, period: 12] do
            register :"#{ch}_#{n}", offset: b + off + o do
              field :value, 0..31, :rw
            end
          end
        end

        register :"#{h}_ptr", offset: b + 0x030, doc: "H2C bytes delivered, modulo ring" do
          field :value, 0..31, :ro
        end

        register :"#{h}_err", offset: b + 0x034, doc: "H2C completion errors" do
          field :value, 0..31, :ro
        end

        register :"#{c}_ptr", offset: b + 0x050, doc: "C2H bytes written, modulo ring" do
          field :value, 0..31, :ro
        end

        register :"#{c}_pkt", offset: b + 0x054, doc: "C2H TLPs written" do
          field :value, 0..31, :ro
        end

        for {ch, base} <- [{h, b + 0x100}, {c, b + 0x140}] do
          for {n, off} <- [dbase_lo: 0x00, dbase_hi: 0x04, wb_lo: 0x18, wb_hi: 0x1C] do
            register :"#{ch}_#{n}", offset: base + off do
              field :value, 0..31, :rw
            end
          end

          register :"#{ch}_dsize", offset: base + 0x08, doc: "Descriptors in the ring" do
            field :value, 0..15, :rw
          end

          register :"#{ch}_dhead", offset: base + 0x0C, doc: "Doorbell: producer index" do
            field :value, 0..15, :rw
          end

          register :"#{ch}_dtail", offset: base + 0x10, doc: "Next descriptor to complete" do
            field :value, 0..15, :ro
          end

          register :"#{ch}_dstat", offset: base + 0x14, doc: "Descriptor ring status" do
            field :halted, 0, :ro, doc: "Ring halted (cleared by run low)"
            field :bad_desc, 1, :ro, doc: "Misaligned or empty descriptor"
            field :fetch_error, 2, :ro, doc: "Descriptor read failed or timed out"
          end

          register :"#{ch}_dctrl", offset: base + 0x20, doc: "Descriptor ring options" do
            field :wb_desc, 0, :rw, doc: "Write status into the descriptor on completion"
            field :wb_head, 1, :rw, doc: "Write the head block to the write-back address"
            field :irq_en, 2, :rw, doc: "Descriptors with the IRQ flag raise the interrupt"
          end

          register :"#{ch}_dcount", offset: base + 0x24, doc: "Descriptors completed" do
            field :value, 0..31, :ro
          end

          register :"#{ch}_dfetch", offset: base + 0x28, doc: "Next descriptor to fetch" do
            field :value, 0..15, :ro
          end
        end
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

  @doc "Byte offset of register `name` (`map/2` with 32 vectors and 4 pairs covers every name)."
  def offset(name), do: ExHdl.Regs.offset(map(32, @max_pairs), name)

  @doc "Register word from field values."
  def encode(name, fields), do: ExHdl.Regs.encode(map(32, @max_pairs), name, fields)

  @doc "Field values of a register word."
  def decode(name, word), do: ExHdl.Regs.decode(map(32, @max_pairs), name, word)

  @doc "The AXI4-Lite slave of `map/2` (holes answer SLVERR)."
  def rtl(vectors \\ 2, pairs \\ 1),
    do: ExHdl.Regs.RTL.build(map(vectors, pairs), unmapped: :slverr)

  @doc "C header text of `map/2`."
  def c_header(vectors \\ 2, pairs \\ 1), do: ExHdl.Regs.CHeader.render(map(vectors, pairs))

  @doc "Markdown table of `map/2`."
  def markdown(vectors \\ 2, pairs \\ 1), do: ExHdl.Regs.Markdown.render(map(vectors, pairs))
end
