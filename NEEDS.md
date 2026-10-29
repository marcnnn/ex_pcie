# Needs from other repositories

Wishes and gaps found while building ex_pcie. Reproducers are minimal;
all were run against the ExHdl checkout next to this repository.

## ExHdl

### 1. `zext` of a nested `mux` of constants lints dirty (WIDTHEXPAND)

```elixir
use ExHdl.RTL

m =
  module "repro_zext_mux" do
    be = input(:be, 4)
    n = input(:n, 3)
    y = output(:y, 5)
    y <~ sub_wrap(cat([n, const(0, 2)]), zext(mux(be[0], const(0, 2), mux(be[1], const(1, 2), const(3, 2))), 5))
  end
```

Generated: `assign y = {n, 2'd0} - 5'((be[0] ? 2'd0 : (be[1] ? 2'd1 : 2'd3)));`

`verilator --lint-only -Wall` reports `WIDTHEXPAND` on the inner
constants: the size cast makes the operands of the conditional
context-width. A single `mux` is fine; the nested one is not. Expected:
the generator wraps the cast operand so it is self-determined, e.g.
`5'(2'(be[0] ? ...))`, or hoists it to a `_t<n>` like other
subexpressions. Workaround in ex_pcie: `wire/2` around the mux.

### 2. An unused instance output fails `-Wall` (UNUSEDSIGNAL)

```elixir
use ExHdl.RTL

child =
  module "child_two_out" do
    a = input(:a, 1)
    x = output(:x, 1)
    y = output(:y, 1)
    x <~ a
    y <~ a
  end

m =
  module "repro_unused_inst_out" do
    a = input(:a, 1)
    q = output(:q, 1)
    u = instance(:u, child)
    u.a <~ a
    q <~ u.x
  end
```

`Verilator`: `Signal is not used: 'u_y'`. The docs say unread signal bits
get `lint_off UNUSEDSIGNAL` pragmas; the `<inst>_<port>` wires of
instances do not. Co-simulation of a top level that leaves a child output
open therefore fails to build. Workaround: route every child output to a
port. Wish: pragma on instance wires (or an `unused: [:y]` instance
option) so top levels need not invent ports.

### 3. `defregs` (done, two wishes left)

`ExPcie.Regs` replaced the stand-in register file. Left over:

* `defregs` has no pulse kind. The old `:pulse` register (output high for
  one cycle carrying the written bits) is a `:wo` field with
  `strobe: :write` plus `kick <~ (reg_field &&& rep(reg_wr, w))` by hand
  (`ExPcie.RTL.Endpoint`, `irq_force`). Wish: `field :vec, 0..1, :pulse`.
* The generated `rtl/0` takes no options, so a map that wants SLVERR for
  holes calls `ExHdl.Regs.RTL.build(map(), unmapped: :slverr)` instead of
  `Map.rtl()`. Wish: `rtl(opts)` forwarding to `ExHdl.Regs.RTL.build/2`.
* Port names are `<reg>_<field>`; for single-field registers named
  `value` that gives `h2c_ring_value`. Wish: an option that drops the
  field name for a register with one field.

### 3a. `cat` of a `mux(sel, list)` fails in SystemVerilog generation (fixed in exhdl 2df191f)

```elixir
use ExHdl.RTL

m =
  module "repro_cat_muxn" do
    sel = input(:sel, 2)
    y = output(:y, 8)
    r = [reg(:r0, 4), reg(:r1, 4), reg(:r2, 4), reg(:r3, 4)]
    sync do
      for x <- r, do: x <~ add_wrap(x, 1)
    end
    y <~ cat([mux(sel, r), const(0, 4)])
  end

ExHdl.Backends.SystemVerilog.RTL.generate(m)
```

Raises `FunctionClauseError` in `String.length/1` with the argument
`:_t1`: `ex/2` for a `:muxn` returns the fresh temporary name as an atom,
and the `:cat` clause measures the strings of its items. The BEAM
simulator accepts the design, so only Verilator, lint and Yosys runs hit
it. Workaround in ex_pcie: `wire/2` around the `mux` before the `cat`
(`H2c`, `slot_dw`). Fix: return `Atom.to_string(name)` (or
`to_string/1` in the `cat` clause).

### 4. Closed-loop co-simulation

`Cosim.compare/3` replays a recorded input trace. The bench in ex_pcie
(`ExPcie.Model.Bench`) runs agents (host models) against the BEAM
simulator, records the inputs of every cycle, and replays them in
Verilator; this works because the DUT is deterministic given its inputs,
but a failing run cannot be diagnosed beyond "output X differs at event
N". Wishes: a generic version of the agent loop in ExHdl (it has no
PCIe knowledge: `drive/2`, `sample/3`, trace recording), and a way to
dump the Verilator VCD for a replayed trace. Partly done on both sides:
`ExHdl.RTL.Bench` runs against a `Cosim.Session`, and `ExPcie.Model.Bench`
now takes `engine: :verilator` (agents against the netlist itself; the
descriptor ring tests use it). Moving ex_pcie to `ExHdl.RTL.Bench` would
need its `Agent` behaviour mapped onto `ExHdl.RTL.Bench.Agent`.

### 5. `Interface.axi_stream` `tkeep` granularity

`tkeep` is one bit per byte. The PCIe streams keep one bit per DWord, so
ex_pcie builds its interfaces with `Interface.new/2`. A `keep: {:unit, 32}`
option (or `keep_bits:`) would let `axi_stream/1` cover this.

### 6. BEAM simulator speed on wide designs

`ExHdl.RTL.Sim` runs the full endpoint (`Endpoint.build(loopback: true)`,
about 4.4k LUTs after synthesis, 49 ports, 256-bit datapaths) at about
1.6k cycles per second idle (H2C alone: 10k). A 1 ms audio period at
250 MHz is 250k cycles, so the tests use periods of 64 to 512 bytes. Not
a bug; a wish for a faster evaluation order (skip unchanged comb cones) if
longer closed-loop runs become useful. The probable hot spot is the 50-way
priority mux of the register read path and the wide `cat`s.

### 7. `memory` style `:auto` picks LUTRAM for 64 x 256

Yosys maps `memory(:fifo, width: 256, depth: 64, style: :auto)` to
distributed RAM (37 RAM cells), not block RAM. That is what `:auto` means
for Vivado too, so no change is requested; `style: :block` gives 8 RAMB18
(`C2h.build(style: :block)`). A note in the `memory/2` docs about the
auto thresholds would help.

### Descriptor rings (done; what they used)

Four RQ producers need `AXIS.packet_mux(4, ...)` (`RqMux.build_n/1`), and
the shared RC stream is fanned out by plain inputs on the extra consumers
(`DescRing` has `rc_tdata`, `rc_tvalid`, `rc_tlast` and no `tready`), the
workaround for item 2: a consumer that only listens has no unused output.
For `DescRing` `stop: false` omits the `d_stop` port for the same reason.
The channel pairs of `Dma` use the same workaround for the H2C channels
of pair 1 and up (`H2c.build(rc_shared: true)`: plain `rc_*` inputs, no
`tready`).
A wish that follows from it: `slave/2` interfaces whose `tready` is
optional (a listener flag), so a second consumer of a stream is a normal
`connect/2`.

## ex_hdl_xilinx

* `PCIE4C` with the CQ/CC/RQ/RC streams, the `cfg_interrupt_msi_*` and
  `cfg_interrupt_msix_*` ports and the `cfg_max_payload`,
  `cfg_max_read_req` outputs, as black boxes whose port names match
  `ExPcie.RTL.Ifc` (`<prefix>_tdata`, ...) plus the core's own naming
  (`m_axis_cq_tdata`, ...), so that the top level only renames.
* A BEAM model of `PCIE4C` is not needed: `ExPcie.Model.Core` covers the
  user side.
* For bring-up with the XDMA IP instead of the own engine: the AXI4-Lite
  master of XDMA (`m_axil_*`) fits `Bar0Bridge`'s downstream side.

## ex_hdl_cores

Used now: `ExHdlCores.AXIL.interconnect/2` (extra register slaves behind
BAR0) and `ExHdlCores.AXIS.packet_mux/2` (`RqMux` is a wrapper of it).
`keep_bits:` in `ExHdlCores.AXIS` covers the one-bit-per-DWord `tkeep` of
item 5 for the blocks that pass `tkeep` through.

## ExHdl, found while moving to ex_hdl_cores and defregs

* An instance named like a prefix of re-exported ports collides: instance
  `mixer` with the port `mixer_ctrl_enable` fails with `mixer_ctrl_enable
  is declared twice`, because instance ports are wires `<inst>_<port>`.
  `Endpoint` therefore calls its instances `u_<name>`. A helper that
  forwards all data ports of an instance to top-level ports with a prefix
  (`expose(inst, prefix: :mixer)`) would replace the loop in
  `ExPcie.RTL.Endpoint.build/1`; the error could name the instance as a
  possible cause.

      module "m" do
        i = instance(:x, child)            # child has the port :y
        output(:x_y, 1) <~ i.y             # ElaborationError: x_y is declared twice
      end
