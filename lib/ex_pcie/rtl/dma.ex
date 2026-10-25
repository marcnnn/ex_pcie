defmodule ExPcie.RTL.Dma do
  @moduledoc """
  The two DMA channels (`ExPcie.RTL.H2c`, `ExPcie.RTL.C2h`) with one
  descriptor ring each (`ExPcie.RTL.DescRing`), sharing the core's RQ and
  RC streams: the four RQ producers go through `ExPcie.RTL.RqMux.build_n/1`.

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

  Completions are routed to the H2C channel (tag bit 7 clear) and to the
  descriptor rings (tag bit 7 set, bit 0 the channel); an RC packet with
  an unknown data tag is counted in the H2C channel as an error.
  """
  use ExHdl.RTL
  alias ExPcie.RTL.{C2h, DescRing, H2c, Ifc, RqMux}

  def build(opts \\ []) do
    module "pcie_dma" do
      rq = master(:rq, Ifc.rq())
      rc = slave(:rc, Ifc.rc())
      hs = master(:h2c_axis, Interface.axi_stream(data: 256, keep: false, last: false))
      cs = slave(:c2h_axis, Interface.axi_stream(data: 256, keep: false))
      mps = input(:cfg_max_payload, 3)
      mrrs = input(:cfg_max_read_req, 3)
      tmo = input(:timeout_cycles, 24)

      h = instance(:h, H2c.build(timeout: :input, desc: true))
      c = instance(:c, C2h.build(Keyword.put(opts, :desc, true)))
      hd = instance(:hd, DescRing.build(channel: 0, stop: false))
      cd = instance(:cd, DescRing.build(channel: 1))
      x = instance(:x, RqMux.build_n(4))

      for {pfx, ch, dr} <- [{:h2c, h, hd}, {:c2h, c, cd}] do
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
      output(:h2c_err_count, 16) <~ h.err_count
      output(:c2h_pkt_count, 16) <~ c.pkt_count

      h.timeout_cycles <~ tmo
      h.cfg_max_read_req <~ mrrs
      c.cfg_max_payload <~ mps

      connect(rc, h.rc)
      connect(h.m_axis, hs)
      connect(cs, c.s_axis)
      connect(h.rq, x.s0)
      connect(c.rq, x.s1)
      connect(hd.rq, x.s2)
      connect(cd.rq, x.s3)
      connect(x.rq, rq)

      c.done <~ x.done[1]
      hd.done <~ x.done[2]
      cd.done <~ x.done[3]
    end
  end
end
