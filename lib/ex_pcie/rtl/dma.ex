defmodule ExPcie.RTL.Dma do
  @moduledoc """
  The DMA channels (`ExPcie.RTL.H2c`, `ExPcie.RTL.C2h`) with one
  descriptor ring each (`ExPcie.RTL.DescRing`), sharing the core's RQ and
  RC streams: the RQ producers (four per channel pair) go through
  `ExPcie.RTL.RqMux.build_n/1`.

  Options: `pairs:` (1 to 4, default 1) channel pairs, each one H2C and
  one C2H channel with its own descriptor ring, simple-ring inputs and
  user streams; `seg_last:` `true` (all pairs), a list of pair numbers or
  `false` (default): the H2C stream of those pairs has `tlast` on the last
  beat of each descriptor segment (`ExPcie.RTL.H2c`); other options go to
  `ExPcie.RTL.C2h.build/1`.

  Pair 0 has the ports below. Pair `p` of `pairs` has the same ports with
  the channel prefix extended by the pair number: `h2c<p>_axis`,
  `c2h<p>_axis`, `h2c<p>_run`, `c2h<p>_ptr`, `h2c<p>_err_count`,
  `c2h<p>_pkt_count`, ... (`h2c1_axis`, `c2h1_axis`, `h2c1_run`, ...).
  `cfg_max_payload`, `cfg_max_read_req`, `timeout_cycles`, `rq` and `rc`
  are shared.

  Ports: `rq` (master), `rc` (slave), `h2c_axis` (master stream, host to
  card), `c2h_axis` (slave stream, card to host), `cfg_max_payload`,
  `cfg_max_read_req`, `timeout_cycles` (H2C completion timeout and
  descriptor fetch timeout, 0 disables), and per channel (`h2c_`, `c2h_`
  prefix) the inputs `run`, `base`, `ring_bytes`, `period_bytes` (simple
  mode) and `desc` (select descriptor mode), `dbase`, `dsize`, `dhead`,
  `wb` (write-back address), `wb_desc`, `wb_head`, `irq_en` (descriptor
  mode, see `ExPcie.RTL.DescRing`) and the outputs `ptr`, `irq`, `dtail`,
  `dcount`, `dfetch`, `dstat`; `h2c_err_count`, `c2h_pkt_count`. See the
  channel modules for the semantics and constraints (aligned `base`, ring a
  multiple of the period, sizes multiples of 32 bytes). `irq` is the
  period interrupt in simple mode and the descriptor interrupt in
  descriptor mode.

  ## PCIe tags

  The tags are 8 bits (the hard block's standard tag field; 10-bit
  extended tags would be a core configuration option that PG213 offers
  but the RQ/RC formats modelled here do not carry, so the partition fits
  8 bits). Bit 7 splits the space in two. LSB first:

  | Use | Bits |
  |---|---|
  | H2C data read | slot [2:0], generation [`5 - k`:3], pair [5:`6 - k`], epoch [6], 0 [7] |
  | descriptor fetch | channel [2:0] (`2 * pair` H2C, `2 * pair + 1` C2H), generation [6:3], 1 [7] |

  with `k = clog2(pairs)`: the pair field takes bits from the H2C
  generation (3 bits with one pair, as before this partition existed; 2
  with two pairs; 1 with three or four), because slot count (eight
  outstanding reads of 256 bytes) and the per-slot epoch bit are what
  hide a stale completion after a timeout and the generation only covers
  the restart case. The descriptor fetch tags keep their 4-bit generation
  and use the three low bits for the channel, which is the old layout
  with `pairs: 1` (bits 2:1 were 0). Four pairs is the limit of this
  partition (the register map has the same limit). At most one read per
  slot of each H2C and one per descriptor ring is outstanding, so a pair
  has 10 reads in flight and the hard block's tag budget (model
  `max_tags`, 32 by default) needs raising for more than three pairs.

  Completions are broadcast to every H2C channel and descriptor ring; each
  accepts only its own tag (an H2C channel ignores bit 7 set and other
  pairs' data tags, the rings compare all 8 bits). An RC packet with a
  data tag of this pair but an unknown slot is counted in this pair's H2C
  channel as an error.

  ## Fairness of the RQ port

  `RqMux` is `ExHdlCores.AXIS.packet_mux/2` with its default
  `:round_robin` arbiter held per packet: once a producer has started a
  packet it is forwarded to its `tlast`, between packets the grant moves
  on from the producer served last to the next one with a packet
  waiting. A busy producer therefore never takes two consecutive packets
  while another one is waiting, and with `4 * pairs` producers each gets
  at least one packet in `4 * pairs`. The share is per packet, not per
  byte (a C2H payload TLP is longer than a descriptor fetch).
  """
  use ExHdl.RTL
  alias ExPcie.RTL.{C2h, DescRing, H2c, Ifc, RqMux}

  @doc false
  # Port prefix of channel `dir` in pair `p`: `h2c`, `h2c1`, ...
  def pfx(dir, 0), do: dir
  def pfx(dir, p), do: :"#{dir}#{p}"

  def build(opts \\ []) do
    pairs = Keyword.get(opts, :pairs, 1)
    unless pairs in 1..4, do: raise(ArgumentError, "pairs must be 1..4")

    seg_last =
      case Keyword.get(opts, :seg_last, false) do
        true -> Enum.to_list(0..(pairs - 1))
        false -> []
        list when is_list(list) -> list
      end

    c2h_opts = opts |> Keyword.drop([:pairs, :seg_last]) |> Keyword.put(:desc, true)

    module "pcie_dma#{if pairs > 1, do: "_p#{pairs}", else: ""}#{if seg_last != [], do: "_sl" <> Enum.join(seg_last), else: ""}" do
      rq = master(:rq, Ifc.rq())
      rc = slave(:rc, Ifc.rc())
      mps = input(:cfg_max_payload, 3)
      mrrs = input(:cfg_max_read_req, 3)
      tmo = input(:timeout_cycles, 24)
      x = instance(:x, RqMux.build_n(4 * pairs))

      for p <- 0..(pairs - 1) do
        hp = pfx(:h2c, p)
        cp = pfx(:c2h, p)
        sl = p in seg_last

        hs =
          master(
            :"#{hp}_axis",
            Interface.axi_stream(data: 256, keep: false, last: sl)
          )

        cs = slave(:"#{cp}_axis", Interface.axi_stream(data: 256, keep: false))

        # instance names of pair 0 are the old ones
        sfx = if p == 0, do: "", else: "#{p}"

        h =
          instance(
            :"h#{sfx}",
            H2c.build(
              timeout: :input,
              desc: true,
              seg_last: sl,
              pair: p,
              pairs: pairs,
              rc_shared: p > 0
            )
          )

        c = instance(:"c#{sfx}", C2h.build(c2h_opts))
        hd = instance(:"hd#{sfx}", DescRing.build(channel: 2 * p, stop: false))
        cd = instance(:"cd#{sfx}", DescRing.build(channel: 2 * p + 1))

        for {pfx, ch, dr} <- [{hp, h, hd}, {cp, c, cd}] do
          run = input(:"#{pfx}_run", 1)
          mode = input(:"#{pfx}_desc", 1)
          ch.run <~ run
          ch.base <~ input(:"#{pfx}_base", 64)
          ch.ring_bytes <~ input(:"#{pfx}_ring_bytes", 32)
          ch.period_bytes <~ input(:"#{pfx}_period_bytes", 32)
          ch.desc_mode <~ mode
          output(:"#{pfx}_ptr", 32) <~ ch.ptr

          dr.run <~ (run and mode)
          dr.dbase <~ input(:"#{pfx}_dbase", 64)
          dr.dsize <~ input(:"#{pfx}_dsize", 16)
          dr.head <~ input(:"#{pfx}_dhead", 16)
          dr.wb_addr <~ input(:"#{pfx}_wb", 64)
          dr.wb_desc <~ input(:"#{pfx}_wb_desc", 1)
          dr.wb_head <~ input(:"#{pfx}_wb_head", 1)
          dr.irq_en <~ input(:"#{pfx}_irq_en", 1)
          dr.timeout_cycles <~ tmo
          dr.rc_tdata <~ rc.tdata
          dr.rc_tvalid <~ rc.tvalid
          dr.rc_tlast <~ rc.tlast

          ch.d_valid <~ dr.d_valid
          ch.d_addr <~ dr.d_addr
          ch.d_len <~ dr.d_len
          ch.d_irq <~ dr.d_irq
          dr.d_next <~ ch.d_next
          ch.cmp_busy <~ dr.cmp_busy
          dr.cmp_valid <~ ch.cmp_valid
          dr.cmp_len <~ ch.cmp_len
          dr.cmp_err <~ ch.cmp_err
          dr.cmp_eop <~ ch.cmp_eop
          dr.cmp_irq <~ ch.cmp_irq

          output(:"#{pfx}_dtail", 16) <~ dr.tail
          output(:"#{pfx}_dcount", 32) <~ dr.count
          output(:"#{pfx}_dfetch", 16) <~ dr.fetch
          output(:"#{pfx}_dstat", 3) <~ dr.stat
          output(:"#{pfx}_irq", 1) <~ (ch.irq or dr.irq)
        end

        c.d_stop <~ cd.d_stop
        output(:"#{hp}_err_count", 16) <~ h.err_count
        output(:"#{cp}_pkt_count", 16) <~ c.pkt_count

        h.timeout_cycles <~ tmo
        h.cfg_max_read_req <~ mrrs
        c.cfg_max_payload <~ mps

        if p == 0 do
          connect(rc, h.rc)
        else
          h.rc_tdata <~ rc.tdata
          h.rc_tkeep <~ rc.tkeep
          h.rc_tlast <~ rc.tlast
          h.rc_tvalid <~ rc.tvalid
        end

        connect(h.m_axis, hs)
        connect(cs, c.s_axis)
        connect(h.rq, x[:"s#{4 * p}"])
        connect(c.rq, x[:"s#{4 * p + 1}"])
        connect(hd.rq, x[:"s#{4 * p + 2}"])
        connect(cd.rq, x[:"s#{4 * p + 3}"])

        c.done <~ x.done[4 * p + 1]
        hd.done <~ x.done[4 * p + 2]
        cd.done <~ x.done[4 * p + 3]
      end

      connect(x.rq, rq)
    end
  end
end
