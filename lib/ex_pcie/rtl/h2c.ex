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
  before a stop are ignored instead of landing in a new request's slot.
  Completions are written into the slot at the offset given by the descriptor's byte count, so they
  may arrive split at any RCB boundary, interleaved and reordered between
  requests (and even out of order within one). The output drains slots in
  request order, one 32-byte beat per cycle. Memory is eight 32-bit wide
  banks so that a completion beat of any DWord alignment writes in one
  cycle.

  Stream `m_axis`: `tdata` (256 bits), `tvalid`, `tready`; no `tlast`
  (the ring is a continuous stream), except with option `seg_last: true`:
  the stream then has `tlast`, high on the last beat of each descriptor
  segment in descriptor mode (never in simple ring mode). The engine reads ahead as far as the
  slots allow and keeps reading the ring in a loop whether or not the
  consumer keeps up.

  Outputs: `rq` master (single-beat requests), `rc` slave (with option
  `rc_shared: true` plain inputs `rc_tdata`, `rc_tkeep`, `rc_tlast`,
  `rc_tvalid` instead, for a channel that listens to a stream another
  consumer owns), `ptr` (ring
  offset in bytes delivered to the stream), `irq` (one-cycle pulse per
  delivered period), `err_count` (completions with error status, poison,
  or an unknown tag of the current generation, counted only while running; an errored request is completed with whatever data
  the slot holds so the stream does not stall).

  Completion timeout: option `timeout:` (cycles, default 50_000 = 200 us at
  250 MHz, inside the PCIe range of 50 us to 50 ms; `nil` disables;
  `:input` adds the 24-bit port `timeout_cycles` instead, 0 disables, which
  `ExPcie.RTL.Dma` connects to the `timeout` register). When
  the oldest outstanding request (the slot that blocks the stream) has
  made no progress for that long, it is completed with whatever its slot
  holds and counted in `err_count`. A per-slot epoch bit in the tag
  (bit 6) flips at every allocation, so a completion arriving after its
  request timed out is dropped instead of landing in the next request of
  that slot (it is only accepted again if the slot was reallocated an
  even number of times in between).

  Descriptor mode (option `desc: true`, selected at run time by the
  `desc_mode` input): instead of looping over the ring, the channel takes
  segments (`d_valid`, `d_addr`, `d_len`, `d_irq`; `d_next` pops one) from an
  `ExPcie.RTL.DescRing`, requests them like the ring (a request never
  crosses the end of a segment), marks the last slot of each segment and,
  when the last beat of a segment was delivered to the stream, reports
  it on `cmp_valid` with `cmp_len`, `cmp_err` (a request of the segment
  failed or timed out) and `cmp_irq`. A segment is 32-byte aligned and a
  multiple of 32 bytes. The period interrupt and `ptr` are not used in
  this mode. Descriptor fetch completions (tag bit 7 set) are ignored here
  and not counted as errors.

  Tag layout (8 bits, LSB first): slot (3), generation (`3 - k`), pair
  number (`k`), epoch (1), 0, where `k = clog2(pairs)` for the options
  `pair:` (this channel's pair, default 0) and `pairs:` (pairs in the
  design, default 1, at most 4). With one pair that is the layout above
  with a 3-bit generation; with 2 pairs the generation has 2 bits, with 3
  or 4 pairs 1 bit. Completions of another pair's data tag (same bit 7
  clear, different pair field) are not this channel's and are neither
  counted nor used; `ExPcie.RTL.Dma` has the whole partition.
  """
  use ExHdl.RTL
  alias ExPcie.RTL.{Ifc, Util}

  @slots 8
  @rows 8

  def build(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 50_000)
    with_desc = Keyword.get(opts, :desc, false)
    seg_last = Keyword.get(opts, :seg_last, false)
    rc_shared = Keyword.get(opts, :rc_shared, false)
    pair = Keyword.get(opts, :pair, 0)
    pairs = Keyword.get(opts, :pairs, 1)
    pb = ExHdl.RTL.Builder.ceil_log2(pairs)
    gb = 3 - pb
    if pairs > 4 or pair >= pairs, do: raise(ArgumentError, "pairs must be 1..4, pair below it")
    if seg_last and not with_desc, do: raise(ArgumentError, "seg_last needs desc: true")

    tw =
      cond do
        timeout == :input -> 24
        timeout -> max(1, Integer.digits(timeout, 2) |> length())
        true -> 1
      end

    name =
      "pcie_h2c#{if with_desc, do: "_desc", else: ""}#{if timeout == :input, do: "_ti", else: ""}" <>
        "#{if seg_last, do: "_sl", else: ""}#{if rc_shared, do: "_rcin", else: ""}#{if pairs > 1, do: "_p#{pair}of#{pairs}", else: ""}"

    module name do
      m = master(:m_axis, Interface.axi_stream(data: 256, keep: false, last: seg_last))
      rq = master(:rq, Ifc.rq())
      rc = unless rc_shared, do: slave(:rc, Ifc.rc())
      run_in = input(:run, 1)
      base = input(:base, 64)
      ring = input(:ring_bytes, 32)
      period = input(:period_bytes, 32)
      mrrs = input(:cfg_max_read_req, 3)
      ptr_o = output(:ptr, 32)
      irq_o = output(:irq, 1)
      err_o = output(:err_count, 16)
      tmo_in = if timeout == :input, do: input(:timeout_cycles, 24)

      # descriptor mode (`desc: true`): segments come from an `ExPcie.RTL.DescRing`
      {desc_mode, d_valid, d_addr, d_len, d_irq, cmp_busy} =
        if with_desc do
          {input(:desc_mode, 1), input(:d_valid, 1), input(:d_addr, 64), input(:d_len, 32),
           input(:d_irq, 1), input(:cmp_busy, 1)}
        else
          {const(0, 1), const(0, 1), const(0, 64), const(0, 32), const(0, 1), const(0, 1)}
        end

      run_q = reg(:run_q, 1)
      gen = reg(:gen, gb)
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
      s_ep = for i <- 0..(@slots - 1), do: reg(:"s_ep#{i}", 1)
      s_last = for i <- 0..(@slots - 1), do: reg(:"s_last#{i}", 1)
      s_irq = for i <- 0..(@slots - 1), do: reg(:"s_irq#{i}", 1)
      s_err = for i <- 0..(@slots - 1), do: reg(:"s_err#{i}", 1)
      seg_valid = reg(:seg_valid, 1)
      seg_len = reg(:seg_len, 32)
      seg_irq = reg(:seg_irq, 1)
      release = wire(:slot_rel, 1)
      err_count = reg(:err_count_r, 16)

      # -- request issue
      req_addr = reg(:req_addr, 64)
      req_off = reg(:req_off, 32)
      rq_v = reg(:rq_v, 1)
      rq_data = reg(:rq_data, 256)

      blk = wire(:blk, req_addr[5..11])
      to4k = wire(:to4k, sub_wrap(const(128, 8), zext(blk, 8)))
      lim = wire(:lim, mux(desc_mode, seg_len, ring))
      to_ring = wire(:to_ring, sub_wrap(lim, req_off)[5..31])
      lim_mrrs = wire(:lim_mrrs, mux(mrrs == 0, const(4, 8), const(@rows, 8)))
      b1 = wire(:b1, mux(lim_mrrs < to4k, lim_mrrs, to4k))
      rb = wire(:rb, mux(to_ring > @rows, const(@rows, 4), trunc(to_ring, 4)))
      beats = wire(:beats, trunc(mux(zext(rb, 8) < b1, zext(rb, 8), b1), 4))
      bytes = wire(:bytes, cat([beats, const(0, 5)]))
      new_off = wire(:new_off, add_wrap(req_off, zext(bytes, 32)))
      wrap = wire(:wrap, new_off == lim)

      alloc =
        wire(:alloc, active and count < @slots and not rq_v and (not desc_mode or seg_valid))

      load = wire(:load, active and desc_mode and d_valid and not seg_valid)
      new_ep = wire(:new_ep, not mux(atail, s_ep))

      pair_bits = if pb == 0, do: [], else: [const(pair, pb)]

      desc =
        Util.desc(:rq, %{
          address: req_addr,
          dw_count: cat([beats, const(0, 3)]),
          req_type: :mem_read,
          tag: cat([const(0, 1), new_ep] ++ pair_bits ++ [gen, atail])
        })

      # -- completion stage 0: register the beat
      r0v = reg(:r0v, 1)
      r0d = reg(:r0d, 256)
      r0k = reg(:r0k, 8)
      r0l = reg(:r0l, 1)
      r0f = reg(:r0f, 1)
      in_pkt = reg(:in_pkt, 1)

      {rc_data, rc_keep, rc_last, rc_valid} =
        if rc_shared do
          {input(:rc_tdata, 256), input(:rc_tkeep, 8), input(:rc_tlast, 1), input(:rc_tvalid, 1)}
        else
          rc.tready <~ 1
          {rc.tdata, rc.tkeep, rc.tlast, rc.tvalid}
        end

      sync do
        r0v <~ rc_valid

        if rc_valid do
          r0d <~ rc_data
          r0k <~ rc_keep
          r0l <~ rc_last
          r0f <~ not in_pkt
          in_pkt <~ not rc_last
        end
      end

      # -- completion stage 1: decode, place, account
      tag0 = wire(:tag0, r0d[64..66])
      ep_ok0 = wire(:ep_ok0, r0d[70] == mux(r0d[64..66], s_ep))

      mine0 =
        wire(
          :mine0,
          if(pb == 0, do: r0d[71] == 0, else: r0d[71] == 0 and r0d[(67 + gb)..69] == pair)
        )

      tag_ok0 = wire(:tag_ok0, r0d[67..(66 + gb)] == gen and ep_ok0 and mine0)
      stale0 = wire(:stale0, (r0d[67..(66 + gb)] != gen or not ep_ok0) and mine0)
      bc0 = wire(:bc0, r0d[18..28])
      dwc0 = wire(:dwc0, r0d[32..42])
      bad0 = wire(:bad0, r0d[43..45] != 0 or r0d[46] or r0d[12..15] != 0)
      ok0 = wire(:ok0, tag_ok0 and mux(tag0, s_busy))
      len0 = wire(:len0, mux(tag0, s_len))
      start0 = wire(:start0, trunc(sub_wrap(zext(len0, 11), bc0), 7))
      pos0 = wire(:pos0, add_wrap(cat([tag0, const(0, 6)]), zext(start0, 9)))

      foreign0 = wire(:foreign0, not mine0)

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

      # -- completion timeout on the head slot (the only one that blocks the stream)
      tmo_hit =
        if timeout do
          tmo = reg(:tmo, tw)
          waiting = wire(:tmo_wait, active and count > 0 and not head_ready)
          progress = wire(:tmo_prog, upd and tag_e == head)

          limit =
            if timeout == :input,
              do: tmo_in != 0 and add_wrap(tmo, 1) == tmo_in,
              else: tmo == timeout - 1

          hit = wire(:tmo_hit, waiting and not progress and limit)

          sync do
            tmo <~ mux(waiting and not progress and not hit, add_wrap(tmo, 1), const(0, tw))
          end

          hit
        else
          wire(:tmo_hit, const(0, 1))
        end

      last_row = wire(:last_row, orow + 1 == orows)
      last_slot = wire(:last_slot, mux(head, s_last))
      fin_row = wire(:fin_row, desc_mode and last_row and last_slot)
      ov_last = reg(:ov_last, 1)
      ov_irq = reg(:ov_irq, 1)
      ov_err = reg(:ov_err, 1)
      ov_len = reg(:ov_len, 32)
      acc_len = reg(:acc_len, 32)
      acc_err = reg(:acc_err, 1)
      slot_dw = wire(:slot_dw, mux(head, s_len))
      slot_bytes = wire(:slot_bytes, zext(cat([slot_dw, const(0, 2)]), 32))
      slot_err = wire(:slot_err, mux(head, s_err))

      advance =
        wire(
          :advance,
          active and head_ready and (not ov or m.tready) and
            (not fin_row or (not cmp_busy and not ov_last))
        )

      release <~ (advance and last_row)
      deliv = wire(:deliv, ov and m.tready)
      raddr = wire(:raddr, cat([head, orow[0..2]]))

      rd = for b <- 0..7, do: read_port(Enum.at(banks, b), addr: raddr, en: advance)
      m.tdata <~ cat(Enum.reverse(rd))
      m.tvalid <~ ov
      if seg_last, do: m.tlast <~ ov_last

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
          if desc_mode and wrap, do: seg_valid <~ 0
        else
          if rq.tready, do: rq_v <~ 0
        end

        for i <- 0..(@slots - 1) do
          if upd and tag_e == i, do: Enum.at(s_got, i) <~ new_got
          if upd and tag_e == i and bad_e, do: Enum.at(s_err, i) <~ 1

          if alloc and atail == i do
            Enum.at(s_last, i) <~ (desc_mode and wrap)
            Enum.at(s_irq, i) <~ seg_irq
            Enum.at(s_err, i) <~ 0
            Enum.at(s_ep, i) <~ new_ep
            Enum.at(s_len, i) <~ cat([beats, const(0, 3)])
            Enum.at(s_got, i) <~ 0
            Enum.at(s_busy, i) <~ 1
          end

          if release and head == i, do: Enum.at(s_busy, i) <~ 0
        end

        count <~ add_wrap(sub_wrap(count, zext(release, 4)), zext(alloc, 4))

        for i <- 0..(@slots - 1) do
          if tmo_hit and head == i, do: Enum.at(s_got, i) <~ Enum.at(s_len, i)
          if tmo_hit and head == i, do: Enum.at(s_err, i) <~ 1
        end

        if load do
          req_addr <~ d_addr
          req_off <~ 0
          seg_len <~ d_len
          seg_irq <~ d_irq
          seg_valid <~ 1
        end

        if r0v do
          cur_tag <~ tag_e
          cur_dwc <~ dwc_e
          cur_ok <~ ok_e
          cur_bad <~ bad_e
          cur_pos <~ add_wrap(pos_e, mux(r0f, const(5, 10), const(8, 10)))

          if r0f and active and (bad0 or not ok0) and not stale0 and not foreign0,
            do: err_count <~ add_wrap(err_count, 1)
        end

        # both in one cycle: the timeout wins, an error completion is rare
        if tmo_hit, do: err_count <~ add_wrap(err_count, 1)

        if advance do
          ov <~ 1
          ov_last <~ fin_row
          orow <~ mux(last_row, const(0, 4), add_wrap(orow, 1))

          if last_row do
            head <~ add_wrap(head, 1)
            acc_len <~ mux(last_slot, const(0, 32), add_wrap(acc_len, slot_bytes))
            acc_err <~ mux(last_slot, const(0, 1), acc_err or slot_err)
          end

          if fin_row do
            ov_len <~ add_wrap(acc_len, slot_bytes)
            ov_err <~ (acc_err or slot_err)
            ov_irq <~ mux(head, s_irq)
          end
        else
          if m.tready do
            ov <~ 0
            ov_last <~ 0
          end
        end

        irq <~ (deliv and out_pleft == 32 and not desc_mode)

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
          seg_valid <~ 0
          acc_len <~ 0
          acc_err <~ 0
          ov_last <~ 0
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

      if with_desc do
        output(:d_next, 1) <~ load
        output(:cmp_valid, 1) <~ (ov and m.tready and ov_last)
        output(:cmp_len, 32) <~ ov_len
        output(:cmp_err, 1) <~ ov_err
        output(:cmp_irq, 1) <~ ov_irq
        output(:cmp_eop, 1) <~ 0
      end
    end
  end
end
