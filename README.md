# ExPcie

PCIe endpoint logic for the UltraScale+ hard block (PCIE4C, Gen3 x8,
256-bit user streams) written with ExHdl, and a host side without a custom
kernel driver (vfio-pci). Target: an AES67 endpoint and audio mixer on the
Alibaba AS02MC04 (XCKU3P) where DMA latency matters more than bandwidth.

## Status

| Part | State |
|---|---|
| TLP codec, PG213 descriptor and stream formats | done, round-trip and property tests; formats written from memory of PG213 (see below) |
| BAR0 bridge (CQ/CC to AXI4-Lite) | done; BEAM simulation against the hard block model, Verilator replay |
| DMA engine (H2C and C2H on RQ/RC, MSI-X per period) | done for contiguous rings; BEAM simulation with random completion splitting, reordering, stalls; Verilator replay |
| Interrupts (MSI-X table in BAR0, MSI) | done |
| Host side (`ExPcie.Device`: mock, sysfs, vfio NIF; `ExPcie.Host`) | done; mock and sysfs tested here, vfio ioctl paths compiled but never run (no card, no IOMMU device on the dev machine) |
| Hard block black box (PCIE4C) and top level, constraints | not here: ex_hdl_xilinx |
| Descriptor rings in host memory (scatter-gather) | not done; contiguous rings only, see Limits |
| On hardware | nothing has run on a card |

`mix test` runs 71 tests and 4 properties (about 100 s): codecs, register file, bridge,
both channels, endpoint, host stack against the simulated card, Verilator
lint and replay, a Yosys synthesis. Tests tagged `:verilator`, `:yosys`,
`:nif` skip themselves when the tool or the NIF is missing.

## Architecture

```
            PCIE4C user side (256 bit, 250 MHz)
   CQ ──┐                                   ┌── CC
   RC ──┼─────────────┐           ┌─────────┼── RQ
        │             │           │         │
   Bar0Bridge      H2c ◄── RC     C2h ──► RqMux ── RQ
   (CQ→AXI-Lite→CC)  │ rq ───────────────────▲
        │            ▼                   ▲
   AXIL interconnect  user stream     user stream
   ├ ExPcie.Regs (BAR0 map, MSI-X table)  IrqCtrl ── cfg_interrupt_msix / msi
   └ more defregs slaves (mixer, PTP, ...)
```

| Module | Role |
|---|---|
| `ExPcie.TLP` | TLP structs and wire codec: MRd, MWr, Cpl, CplD, byte counts, RCB completion splitting |
| `ExPcie.Desc` | CQ, CC, RQ, RC descriptors as integers and field maps |
| `ExPcie.Axis` | beats (`data`, DWord `keep`, `last`, `user`) and the conversion to and from TLPs |
| `ExPcie.RTL.Ifc` | the four streams as ExHdl interfaces |
| `ExPcie.RTL.Bar0Bridge` | completer: 1 to 4 DWord MMIO reads and writes, completions, UR and CA handling |
| `ExPcie.Regs` | the BAR0 register map as an `ExHdl.Regs` map: AXI4-Lite slave, host offsets and encode/decode, C header, Markdown |
| `ExPcie.RTL.H2c`, `C2h` | the DMA channels |
| `ExPcie.RTL.RqMux` | packet arbiter for the single RQ stream (wraps `ExHdlCores.AXIS.packet_mux/2`) |
| `ExPcie.RTL.IrqCtrl` | MSI-X (table in BAR0) and MSI requests, retry on failure |
| `ExPcie.RTL.Dma`, `Endpoint` | both channels with the mux; the whole endpoint (`loopback: true` loops the user streams for self-test; `extra:` adds register slaves behind the BAR) |
| `ExPcie.Model.Core` | BEAM model of the hard block and the host (memory, completer, requester, interrupts) |
| `ExPcie.Model.Bench`, `Agent`, `Stream`, `Pins` | closed-loop bench around `ExHdl.RTL.Sim`, records the stimulus for Verilator |
| `ExPcie.Dma.Ref` | timing-free reference: TLP segmentation, ring contents, read requests |
| `ExPcie.Device` (`Mock`, `Sysfs`, `Vfio`), `ExPcie.Nif` | host access |
| `ExPcie.Host` | driver for the endpoint's register map (offsets from `ExPcie.Regs`), rings, pointers, interrupts |
| `ExPcie.Sim.Card` | the endpoint RTL in the simulator behind a mock `ExPcie.Device` |

### DMA channels

A ring is a contiguous region of host memory (one IOMMU mapping makes any
size contiguous in IOVA space) described by `base`, `ring_bytes`,
`period_bytes` in BAR0 registers. The channels run in a loop until the run
bit is cleared and never wait for the host; the host follows with the
pointer registers and the period interrupts.

* **C2H** (card to host): the user stream (256-bit beats, `tlast` closes a
  TLP early) goes into a 64-beat buffer and out as posted memory writes of
  at most MPS bytes, split at 4 KiB boundaries and period ends. One TLP in
  flight; after the last beat of a period crossed the RQ port, MSI-X vector
  1 is requested (the interrupt follows the data in the same order a
  posted write would).
* **H2C** (host to card): eight 256-byte slots, tag = slot plus a
  generation. Completions are written into banked memory at the offset
  their byte count gives, so they may be split at any RCB boundary and
  arrive interleaved or reordered. The slots drain in request order, one
  beat per cycle, into the user stream; vector 0 fires when a period has
  been delivered.
* Latency (RTL only, ideal core): C2H from the last beat of a period to
  the MSI-X request 9 cycles (36 ns at 250 MHz); H2C from `run` to the
  first beat 15 cycles with a 4-cycle host. PCIe and host latency come on
  top. Periods are free: the audio period (1 ms or 64 frames) is just
  `period_bytes`, and `tlast` flushes sub-period TLPs.
* Resources (Yosys, `synth_xilinx -family xcup`, whole endpoint): about
  3.8k LUT, 3.9k FF, 77 LUTRAM cells, no BRAM or DSP (`C2h.build(style:
  :block)` uses 8 RAMB18 instead of LUTRAM).

### BAR0 map and more register slaves

The endpoint's registers are declared once in `ExPcie.Regs` (`ExHdl.Regs`,
`defregs` style): ID `0x50434945` at 0, `caps` at 4, `ctrl` at 0x10, per
channel `base_lo/hi`, `ring`, `period`, `ptr`, MSI-X table at 0x1000
(16 bytes per vector), PBA at 0x2000; `ExPcie.Regs.markdown/1` and
`c_header/1` print the table. `ExPcie.Host.offset/1` reads the same map,
`ExPcie.Host.fields/2` and `write_fields/3` decode and encode by field
name. The offsets are the ones of the register file this replaced
(`test/regs_test.exs` pins them). What changed: register ports are named
`<reg>_<field>` (`ctrl_h2c_run`, `status_h2c_error_set`), `id` and `caps`
are constants, `irq_force` is a write-only field with a strobe, and the
slave is `ExHdl.Regs.RTL` (one access at a time, byte strobes, SLVERR for
holes).

Further `defregs` slaves (audio mixer, PTP readout, ...) live behind the
same BAR0: the endpoint then puts `ExHdlCores.AXIL.interconnect/2` between
the bridge and the slaves.

```elixir
Endpoint.build(extra: [
  %{name: :mixer, base: 0x4000, module: Mixer.Regs.rtl()},   # 4 KiB at 0x4000
  %{name: :ptp, base: 0x8000, module: Ptp.Regs.rtl()},
  %{name: :ext, base: 0x10000, size: 0x1000}                 # AXI4-Lite master port instead
])
```

`base` is a multiple of the slave's size (`2^address bits` of its
`s_axil`), at or above 0x4000 (the endpoint's own range is 0x0000 to
0x3FFF). The ports of each module come out with the prefix `<name>_`
(`mixer_ctrl_enable`, `ptp_time_lo_value`, ...); `ext` exposes
`ext_axil_*`. The core's BAR0 aperture must cover the highest range.
Unmapped addresses between and above the slaves complete with SLVERR (a
read becomes a Completer Abort, a write counts in `axil_err`). The access
latency of the extra slaves is the interconnect's (two cycles) plus the
slave's. Without `extra:` there is no interconnect.

## Host side

```elixir
{:ok, dev} = ExPcie.Device.open(:vfio, bdf: "0000:03:00.0")   # or :sysfs, :mock
:ok = ExPcie.Host.check_id(dev)
{:ok, rx} = ExPcie.Device.alloc_dma(dev, 1_048_576)        # IOMMU-mapped
:ok = ExPcie.Host.start_c2h(dev, rx, period: 4096)
:ok = ExPcie.Device.subscribe_irq(dev, ExPcie.Host.vector(:c2h))
:ok = ExPcie.Host.wait_irq(dev, 1, 100)
ptr = ExPcie.Host.ptr(dev, :c2h)
```

Without a card, `ExPcie.Sim.Card.open/1` returns a mock device backed by
the simulated endpoint, so the same code runs against the RTL (see
`test/host_test.exs`).

The NIF (`c_src/ex_pcie_nif.c`, plain C, built by `make` from the mix
compiler `:ex_pcie_nif`) is optional: without `make` and a C compiler, or
if the build fails, compile and tests still work and only `:vfio` and
mmap-based `:sysfs` need it (`:sysfs` falls back to `pread`/`pwrite`).

### Binding the card to vfio-pci

One time, as root (a udev rule or systemd unit makes it permanent):

```sh
# the IOMMU must be on: intel_iommu=on or amd_iommu=on (and iommu=pt) on the
# kernel command line; /sys/kernel/iommu_groups/ must list the device
lspci -nn | grep -i xilinx                       # note the BDF, e.g. 03:00.0
modprobe vfio-pci
echo vfio-pci > /sys/bus/pci/devices/0000:03:00.0/driver_override
echo 0000:03:00.0 > /sys/bus/pci/drivers_probe   # unbinds the old driver if any
ls -l /dev/vfio/                                 # one node per IOMMU group
chown :audio /dev/vfio/<group> /dev/vfio/vfio    # or a udev rule for your user
```

Then as the unprivileged user: raise the locked-memory limit
(`ulimit -l unlimited` or `LimitMEMLOCK=infinity` in the unit; DMA buffers
are pinned) and open the device as above. All devices in the IOMMU group
must be bound to vfio-pci or to nothing. Without an IOMMU,
`modprobe vfio enable_unsafe_noiommu_mode=1` gives a root-only fallback
that this library does not support.

`:sysfs` needs no binding, only `chmod` on
`/sys/bus/pci/devices/<bdf>/resource0` and an enabled device
(`echo 1 > enable`), and gives BAR access only.

MSI-X: the table is in BAR0, so with vfio the kernel writes it when the
NIF enables the vectors (`irq_kind: :msix`). `ExPcie.Host.program_msix/4`
exists for setups where nothing does.

## PG213 formats written from memory

Nothing here was checked against the Xilinx guide or a core. Check these
before the first synthesis (listed in `ExPcie.Axis`):

* `tuser` widths (CQ 88, CC 33, RQ 62, RC 75) and bit positions; only
  `first_be`, `last_be`, `discontinue` are used by the RTL.
* Descriptor field positions of all four kinds (`ExPcie.Desc`), in
  particular the RC `error_code` values and CC `dw_count` 0 for
  completions without data.
* DWord-granular `tkeep`, DWord-aligned payload (payload right behind the
  descriptor), no RC straddling at 256 bits.
* Requester ID and completer ID filled in by the core, tags managed by
  the user logic, a pulse on `cfg_interrupt_msix_int` / `msi_int` answered
  by `sent` or `fail`, MSI-X interrupt ordered behind earlier RQ writes.
* The credit scheme of `cq_np_req` (one pulse per credit, up to four).

The model (`ExPcie.Model.Core`) encodes the same assumptions, so tests
passing means the RTL agrees with this reading of PG213, not that it
agrees with the core.

## Limits

* Rings are contiguous; no descriptor rings or scatter-gather. `base`,
  `ring`, `period` multiples of 32 bytes, `ring` a multiple of `period`.
* C2H packets are whole 32-byte beats; one write TLP in flight.
* H2C requests are at most 256 bytes, at most eight outstanding; after
  clearing `run`, completions still in flight are ignored through the tag
  generation, not waited for.
* H2C completion timeout: the oldest outstanding read gives up after
  `H2c.build(timeout: cycles)` (default 50_000, 200 us) without progress;
  its bytes in the stream are then undefined and `h2c_err` counts it.
  Only the head slot is timed, so a lost read behind it times out once it
  becomes the head. C2H writes are posted and have no timeout.
* MMIO: 1 to 4 DWords per TLP, one request at a time, BAR0 only (other
  BARs get UR for reads). Atomics, I/O and locked reads get UR.
* Interrupts: no timeout for a core that never answers; legacy INTx not
  supported.
* 256-bit streams only; a single function, no SR-IOV.
* The BEAM simulation runs the whole endpoint at about 1.6k cycles per
  second, so tests use periods of 64 to 512 bytes.

## Development

```sh
./scripts/checkout_siblings.sh   # path dependencies on ../exhdl and ../ex_hdl_cores
mix test
mix format --check-formatted && mix compile --warnings-as-errors
```

Open questions for the sibling libraries are in `NEEDS.md`.
