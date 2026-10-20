defmodule ExPcie.RTL.H2c do
  @moduledoc """
  Host-to-card DMA channel: a circular buffer in host memory read with
  memory read requests on RQ and streamed out as AXI4-Stream, one interrupt
  per period consumed.

  Configuration inputs (stable while `run` is high; `run` low resets the
  channel): `base` (64-bit host address, 32-byte aligned), `ring_bytes`
  and `period_bytes` (multiples of 32), `cfg_max_read_req` (the core's
  code, 0 = 128 B, 1 = 256 B, ...). Requests are at most 256 bytes (one
  slot), never cross a 4 KiB boundary or the end of the ring.

  Eight slots of 256 bytes sit between RC and the stream. A request owns a
  slot; its tag is the slot number plus a 3-bit generation that changes
  at every start (`run` rising), so completions still in flight from
  before a stop are ignored instead of landing in a new request's slot. Completions are written into
  the slot at the offset given by the descriptor's byte count, so they
  may arrive split at any RCB boundary, interleaved and reordered between
  requests (and even out of order within one). The output drains slots in
  request order, one 32-byte beat per cycle. Memory is eight 32-bit wide
  banks so that a completion beat of any DWord alignment writes in one
  cycle.

  Stream `m_axis`: `tdata` (256 bits), `tvalid`, `tready`; no `tlast`
  (the ring is a continuous stream). The engine reads ahead as far as the
  slots allow and keeps reading the ring in a loop whether or not the
  consumer keeps up.

  Outputs: `rq` master (single-beat requests), `rc` slave, `ptr` (ring
  offset in bytes delivered to the stream), `irq` (one-cycle pulse per
  delivered period), `err_count` (completions with error status, poison,
  or an unknown tag of the current generation, counted only while running; an errored request is completed with whatever data
  the slot holds so the stream does not stall).
  """
  use ExHdl.RTL
  alias ExPcie.RTL.{Ifc, Util}

  @slots 8
  @rows 8

  def build(_opts \\ []) do
    module "pcie_h2c" do
      m = master(:m_axis, Interface.axi_stream(data: 256, keep: false, last: false))
      rq = master(:rq, Ifc.rq())
      rc = slave(:rc, Ifc.rc())
      run_in = input(:run, 1)
      base = input(:base, 64)
      ring = input(:ring_bytes, 32)
      period = input(:period_bytes, 32)
      mrrs = input(:cfg_max_read_req, 3)
      ptr_o = output(:ptr, 32)
      irq_o = output(:irq, 1)
      err_o = output(:err_count, 16)

      run_q = reg(:run_q, 1)
      gen = reg(:gen, 3)
      active = wire(:active, run_in and run_q)

      sync do
        run_q <~ run_in
        if run_in and not run_q, do: gen <~ add_wrap(gen, 1)
      end

      # -- slot state
      count = reg(:count, 4)
      head = reg(:head, 3)
      atail = reg(:atail, 3)
      s_len = for i <- 0..(@slots - 1), do: reg(:"s_len#{i}", 7)
      s_got = for i <- 0..(@slots - 1), do: reg(:"s_got#{i}", 7)
      s_busy = for i <- 0..(@slots - 1), do: reg(:"s_busy#{i}", 1)
      release = wire(:slot_rel, 1)
      err_count = reg(:err_count_r, 16)

      # -- request issue
      req_addr = reg(:req_addr, 64)
      req_off = reg(:req_off, 32)
      rq_v = reg(:rq_v, 1)
      rq_data = reg(:rq_data, 256)

      blk = wire(:blk, req_addr[5..11])
      to4k = wire(:to4k, sub_wrap(const(128, 8), zext(blk, 8)))
      to_ring = wire(:to_ring, sub_wrap(ring, req_off)[5..31])
      lim_mrrs = wire(:lim_mrrs, mux(mrrs == 0, const(4, 8), const(@rows, 8)))
      b1 = wire(:b1, mux(lim_mrrs < to4k, lim_mrrs, to4k))
      rb = wire(:rb, mux(to_ring > @rows, const(@rows, 4), trunc(to_ring, 4)))
      beats = wire(:beats, trunc(mux(zext(rb, 8) < b1, zext(rb, 8), b1), 4))
      bytes = wire(:bytes, cat([beats, const(0, 5)]))
      new_off = wire(:new_off, add_wrap(req_off, zext(bytes, 32)))
      wrap = wire(:wrap, new_off == ring)
      alloc = wire(:alloc, active and count < @slots and not rq_v)

      desc =
        Util.desc(:rq, %{
          address: req_addr,
          dw_count: cat([beats, const(0, 3)]),
          req_type: :mem_read,
          tag: cat([const(0, 2), gen, atail])
        })

      # -- completion stage 0: register the beat
      r0v = reg(:r0v, 1)
      r0d = reg(:r0d, 256)
      r0k = reg(:r0k, 8)
      r0l = reg(:r0l, 1)
      r0f = reg(:r0f, 1)
      in_pkt = reg(:in_pkt, 1)
      rc.tready <~ 1

      sync do
        r0v <~ rc.tvalid

        if rc.tvalid do
          r0d <~ rc.tdata
          r0k <~ rc.tkeep
          r0l <~ rc.tlast
          r0f <~ not in_pkt
          in_pkt <~ not rc.tlast
        end
      end

      # -- completion stage 1: decode, place, account
      tag0 = wire(:tag0, r0d[64..66])
      tag_ok0 = wire(:tag_ok0, r0d[67..69] == gen and r0d[70..71] == 0)
      stale0 = wire(:stale0, r0d[67..69] != gen and r0d[70..71] == 0)
      bc0 = wire(:bc0, r0d[18..28])
      dwc0 = wire(:dwc0, r0d[32..42])
      bad0 = wire(:bad0, r0d[43..45] != 0 or r0d[46] or r0d[12..15] != 0)
      ok0 = wire(:ok0, tag_ok0 and mux(tag0, s_busy))
      len0 = wire(:len0, mux(tag0, s_len))
      start0 = wire(:start0, trunc(sub_wrap(zext(len0, 11), bc0), 7))
      pos0 = wire(:pos0, add_wrap(cat([tag0, const(0, 6)]), zext(start0, 9)))

      cur_tag = reg(:cur_tag, 3)
      cur_dwc = reg(:cur_dwc, 11)
      cur_ok = reg(:cur_ok, 1)
      cur_bad = reg(:cur_bad, 1)
      cur_pos = reg(:cur_pos, 10)

      tag_e = wire(:tag_e, mux(r0f, tag0, cur_tag))
      dwc_e = wire(:dwc_e, mux(r0f, dwc0, cur_dwc))
      ok_e = wire(:ok_e, mux(r0f, ok0, cur_ok))
      bad_e = wire(:bad_e, mux(r0f, bad0, cur_bad))
      pos_e = wire(:pos_e, mux(r0f, zext(pos0, 10), cur_pos))
      pb = wire(:pb, add_wrap(pos_e, mux(r0f, const(5, 10), const(8, 10))))
      write_ok = wire(:write_ok, r0v and ok_e and not bad_e)
      len_e = wire(:len_e, mux(tag_e, s_len))
      got_e = wire(:got_e, mux(tag_e, s_got))
      upd = wire(:upd, r0v and r0l and ok_e)
      new_got = wire(:new_got, mux(bad_e, len_e, add_wrap(got_e, trunc(dwc_e, 7))))

      # -- banks
      banks = for b <- 0..7, do: memory(:"bank#{b}", width: 32, depth: @slots * @rows)

      for b <- 0..7 do
        lsel = wire(:"lsel#{b}", sub_wrap(const(b, 3), pb[0..2]))
        lane_ok = wire(:"lane_ok#{b}", not r0f or lsel >= 3)
        keep_ok = wire(:"keep_ok#{b}", r0k[lsel])
        row = wire(:"row#{b}", trunc(sub_wrap(add_wrap(pb, zext(lsel, 10))[3..9], 1), 6))

        write_port(Enum.at(banks, b),
          addr: row,
          data: mux(lsel, for(l <- 0..7, do: Util.lane(r0d, l))),
          en: write_ok and lane_ok and keep_ok
        )
      end

      # -- output side
      orow = reg(:orow, 4)
      ov = reg(:ov, 1)
      out_off = reg(:out_off, 32)
      out_pleft = reg(:out_pleft, 32)
      irq = reg(:irq_r, 1)

      head_ready = wire(:head_ready, count > 0 and mux(head, s_got) == mux(head, s_len))
      orows = wire(:orows, mux(head, s_len)[3..6])
      advance = wire(:advance, active and head_ready and (not ov or m.tready))
      last_row = wire(:last_row, orow + 1 == orows)
      release <~ (advance and last_row)
      deliv = wire(:deliv, ov and m.tready)
      raddr = wire(:raddr, cat([head, orow[0..2]]))

      rd = for b <- 0..7, do: read_port(Enum.at(banks, b), addr: raddr, en: advance)
      m.tdata <~ cat(Enum.reverse(rd))
      m.tvalid <~ ov

      rq.tdata <~ rq_data
      rq.tkeep <~ 0x0F
      rq.tlast <~ 1
      rq.tuser <~ 0xFF
      rq.tvalid <~ rq_v

      sync do
        if alloc do
          rq_v <~ 1
          rq_data <~ zext(desc, 256)
          req_off <~ mux(wrap, const(0, 32), new_off)
          req_addr <~ mux(wrap, base, add_wrap(req_addr, zext(bytes, 64)))
          atail <~ add_wrap(atail, 1)
        else
          if rq.tready, do: rq_v <~ 0
        end

        for i <- 0..(@slots - 1) do
          if upd and tag_e == i, do: Enum.at(s_got, i) <~ new_got

          if alloc and atail == i do
            Enum.at(s_len, i) <~ cat([beats, const(0, 3)])
            Enum.at(s_got, i) <~ 0
            Enum.at(s_busy, i) <~ 1
          end

          if release and head == i, do: Enum.at(s_busy, i) <~ 0
        end

        count <~ add_wrap(sub_wrap(count, zext(release, 4)), zext(alloc, 4))

        if r0v do
          cur_tag <~ tag_e
          cur_dwc <~ dwc_e
          cur_ok <~ ok_e
          cur_bad <~ bad_e
          cur_pos <~ add_wrap(pos_e, mux(r0f, const(5, 10), const(8, 10)))

          if r0f and active and (bad0 or not ok0) and not stale0,
            do: err_count <~ add_wrap(err_count, 1)
        end

        if advance do
          ov <~ 1
          orow <~ mux(last_row, const(0, 4), add_wrap(orow, 1))
          if last_row, do: head <~ add_wrap(head, 1)
        else
          if m.tready, do: ov <~ 0
        end

        irq <~ (deliv and out_pleft == 32)

        if deliv do
          out_off <~ mux(add_wrap(out_off, 32) == ring, const(0, 32), add_wrap(out_off, 32))
          out_pleft <~ mux(out_pleft == 32, period, sub_wrap(out_pleft, 32))
        end

        if not active do
          count <~ 0
          head <~ 0
          atail <~ 0
          req_off <~ 0
          req_addr <~ base
          rq_v <~ 0
          orow <~ 0
          ov <~ 0
          out_off <~ 0
          out_pleft <~ period
          for i <- 0..(@slots - 1), do: Enum.at(s_busy, i) <~ 0
        end
      end

      ptr_o <~ out_off
      irq_o <~ irq
      err_o <~ err_count
    end
  end
end
