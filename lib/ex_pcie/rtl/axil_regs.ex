defmodule ExPcie.RTL.AxilRegs do
  @moduledoc """
  A 32-bit AXI4-Lite register file generated from a list of registers
  (a stand-in until ExHdl's `defregs` is available). Register kinds:

    * `:rw` - output `<name>`, written with byte strobes, optional `reset:`
    * `:ro` - input `<name>`, read only
    * `:w1c` - sticky status: input `<name>_set` (events), output `<name>`,
      host writes 1 to clear (an event in the same cycle wins)
    * `:pulse` - output `<name>`, high for one cycle carrying the written
      bits (doorbells, run/clear commands)

  Each register is `%{name: atom, offset: byte offset, kind: kind, width:
  1..32}` (width default 32, offset a multiple of 4). Reads and writes
  take two cycles and one transfer at a time; unmapped offsets answer
  SLVERR (`resp = 2`), writes to `:ro` registers are ignored (OKAY).
  The slave port is `s_axil`.
  """
  use ExHdl.RTL
  alias ExPcie.RTL.Util

  @type reg :: %{name: atom(), offset: non_neg_integer(), kind: atom(), width: pos_integer()}

  def build(name, regs, opts \\ []) do
    ab = Keyword.get(opts, :addr_bits, 16)
    regs = Enum.map(regs, &Map.merge(%{width: 32, reset: 0}, &1))
    check!(regs, ab)

    module name do
      s = slave(:s_axil, Interface.axi_lite(addr: ab, data: 32))

      bvalid = reg(:bvalid_r, 1)
      bresp = reg(:bresp_r, 2)
      rvalid = reg(:rvalid_r, 1)
      rresp = reg(:rresp_r, 2)
      rdata = reg(:rdata_r, 32)

      do_wr = wire(:do_wr, s.awvalid and s.wvalid and not bvalid)
      do_rd = wire(:do_rd, s.arvalid and not rvalid)
      s.awready <~ do_wr
      s.wready <~ do_wr
      s.arready <~ do_rd
      s.bvalid <~ bvalid
      s.bresp <~ bresp
      s.rvalid <~ rvalid
      s.rresp <~ rresp
      s.rdata <~ rdata

      widx = wire(:widx, s.awaddr[2..(ab - 1)])
      ridx = wire(:ridx, s.araddr[2..(ab - 1)])

      strb_mask =
        wire(:strb_mask, cat(for b <- 3..0//-1, do: rep(s.wstrb[b], 8)))

      wdata = wire(:wdata_m, s.wdata &&& strb_mask)

      # -- registers
      handles =
        for r <- regs, into: %{} do
          w = r.width
          sel = wire(:"wsel_#{r.name}", do_wr and widx == div(r.offset, 4))
          full = rep(const(1, 1), w)

          h =
            case r.kind do
              :rw ->
                out = output(:"#{r.name}", w)
                v = reg(:"#{r.name}_r", w, reset: r.reset)

                sync do
                  if sel, do: v <~ trunc((s.wdata &&& strb_mask) ||| (v &&& ~~~strb_mask), w)
                end

                out <~ v
                v

              :ro ->
                input(:"#{r.name}", w)

              :w1c ->
                set = input(:"#{r.name}_set", w)
                out = output(:"#{r.name}", w)
                v = reg(:"#{r.name}_r", w, reset: 0)
                clr = wire(:"#{r.name}_clr", mux(sel, trunc(wdata, w), const(0, w)))

                sync do
                  v <~ ((v &&& ~~~clr) ||| set)
                end

                out <~ v
                v

              :pulse ->
                out = output(:"#{r.name}", w, reset: 0)

                sync do
                  out <~ mux(sel, trunc(wdata, w), const(0, w))
                end

                out
            end

          _ = full
          {r.name, h}
        end

      known = Enum.reduce(regs, const(0, 1), fn r, acc -> acc or widx == div(r.offset, 4) end)
      rknown = Enum.reduce(regs, const(0, 1), fn r, acc -> acc or ridx == div(r.offset, 4) end)

      read_val =
        Enum.reduce(regs, const(0, 32), fn r, acc ->
          v =
            case r.kind do
              :pulse -> const(0, 32)
              _ -> zext(handles[r.name], 32)
            end

          mux(ridx == div(r.offset, 4), v, acc)
        end)

      sync do
        if do_wr do
          bvalid <~ 1
          bresp <~ mux(known, const(0, 2), const(2, 2))
        else
          if s.bready, do: bvalid <~ 0
        end

        if do_rd do
          rvalid <~ 1
          rdata <~ mux(rknown, read_val, const(0, 32))
          rresp <~ mux(rknown, const(0, 2), const(2, 2))
        else
          if s.rready, do: rvalid <~ 0
        end
      end

      _ = Util
    end
  end

  defp check!(regs, ab) do
    offs = Enum.map(regs, & &1.offset)

    if length(Enum.uniq(offs)) != length(offs),
      do: raise(ArgumentError, "duplicate register offsets")

    for r <- regs do
      if rem(r.offset, 4) != 0 or r.offset >= Bitwise.bsl(1, ab),
        do: raise(ArgumentError, "register #{r.name}: bad offset #{r.offset}")

      if r.kind not in [:rw, :ro, :w1c, :pulse],
        do: raise(ArgumentError, "register #{r.name}: bad kind #{inspect(r.kind)}")
    end
  end
end
