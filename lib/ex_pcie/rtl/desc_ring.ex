defmodule ExPcie.RTL.DescRing do
  @moduledoc """
  Descriptor ring of one DMA channel: fetches descriptors from a ring in
  host memory, hands them to the data engine (`ExPcie.RTL.H2c` or
  `ExPcie.RTL.C2h` in descriptor mode), and writes completion status back.
  The format is described in `ExPcie.DRing`.

  Option `stop: false` omits `d_stop` (the host-to-card engine has no use
  for it); `channel:` (0 or 1) distinguishes the two units in the tags.

  Fetch: the host advances the producer index `head` (the doorbell
  register); while it differs from the fetch index the unit reads the next
  32-byte descriptor with a memory read on RQ (tag bit 7 set, bit 0 the
  `channel:` option, bits 6:3 a generation that changes at every start),
  keeps one descriptor ahead of the engine and presents the oldest on
  `d_valid`, `d_addr`, `d_len`, `d_irq`, `d_stop`; `d_next` consumes it.
  A descriptor that is misaligned (address or length not a multiple of 32
  bytes), has length zero or length 2^28 and up, a completion with an error
  status, or a read without answer within `timeout_cycles` (0 disables)
  halts the ring: nothing is fetched until `run` goes low (`stat` bit 0
  halted, bit 1 bad descriptor, bit 2 fetch error); descriptors already
  handed to the engine complete normally.

  Completion: the engine reports each finished descriptor, in order, with
  `cmp_valid` (and `cmp_len` bytes transferred, `cmp_err`, `cmp_eop`,
  `cmp_irq`) only while `cmp_busy` is low; one report is held at a time.
  For a report the unit writes, one posted write each, the status words
  (`wb_desc`: DWords 6 and 7 of the descriptor in host memory) and the
  head pointer block (`wb_head`: at `wb_addr`, DWord 0 the new tail index,
  DWord 1 the number of descriptors completed), waits for `done` (the RQ
  mux transferred the last beat of the packet) after each, then advances
  `tail`, and raises `irq` for one cycle when the descriptor asked for it
  and `irq_en` is set, so the interrupt follows the write-back like a
  posted write would. Every packet of this unit waits for the previous
  one's `done`.

  Completions arrive on plain `rc_*` inputs shared with other consumers
  (this unit ignores packets whose tag is not its own and never
  back-pressures). Indices run from 0 to `dsize - 1`; the host keeps at
  most `dsize - 1` descriptors posted. `run` low resets the unit.
  """
  use ExHdl.RTL
  alias ExPcie.RTL.{Ifc, Util}

  def build(opts \\ []) do
    ch = Keyword.get(opts, :channel, 0)
    stop = Keyword.get(opts, :stop, true)

    module "pcie_desc_ring_#{ch}#{if stop, do: "", else: "_nostop"}" do
      rq = master(:rq, Ifc.rq())
      rc_d = input(:rc_tdata, 256)
      rc_v = input(:rc_tvalid, 1)
      rc_l = input(:rc_tlast, 1)
      run_in = input(:run, 1)
      dbase = input(:dbase, 64)
      dsize = input(:dsize, 16)
      head = input(:head, 16)
      wb_addr = input(:wb_addr, 64)
      wb_desc = input(:wb_desc, 1)
      wb_head = input(:wb_head, 1)
      irq_en = input(:irq_en, 1)
      tmo_in = input(:timeout_cycles, 24)
      done = input(:done, 1)
      d_next = input(:d_next, 1)
      cmp_v = input(:cmp_valid, 1)
      cmp_len = input(:cmp_len, 32)
      cmp_err = input(:cmp_err, 1)
      cmp_eop = input(:cmp_eop, 1)
      cmp_irq = input(:cmp_irq, 1)

      d_valid_o = output(:d_valid, 1)
      d_addr_o = output(:d_addr, 64)
      d_len_o = output(:d_len, 32)
      d_irq_o = output(:d_irq, 1)
      d_stop_o = if stop, do: output(:d_stop, 1)
      busy_o = output(:cmp_busy, 1)
      irq_o = output(:irq, 1)
      tail_o = output(:tail, 16)
      count_o = output(:count, 32)
      fetch_o = output(:fetch, 16)
      stat_o = output(:stat, 3)

      run_q = reg(:run_q, 1)
      gen = reg(:gen, 4)
      active = wire(:active, run_in and run_q)

      sync do
        run_q <~ run_in
        if run_in and not run_q, do: gen <~ add_wrap(gen, 1)
      end

      fidx = reg(:fidx, 16)
      tail = reg(:tail_r, 16)
      cnt = reg(:cnt_r, 32)
      halted = reg(:halted, 1)
      bad = reg(:bad, 1)
      ferr = reg(:ferr, 1)
      f_busy = reg(:f_busy, 1)
      f_tmo = reg(:f_tmo, 24)
      tx_busy = reg(:tx_busy, 1)

      o_valid = reg(:o_valid, 1)
      o_addr = reg(:o_addr, 64)
      o_len = reg(:o_len, 28)
      o_irq = reg(:o_irq, 1)
      o_stop = reg(:o_stop, 1)
      n_valid = reg(:n_valid, 1)
      n_addr = reg(:n_addr, 64)
      n_len = reg(:n_len, 28)
      n_irq = reg(:n_irq, 1)
      n_stop = reg(:n_stop, 1)

      ev_valid = reg(:ev_valid, 1)
      ev_len = reg(:ev_len, 32)
      ev_err = reg(:ev_err, 1)
      ev_eop = reg(:ev_eop, 1)
      ev_irq = reg(:ev_irq, 1)
      irq_r = reg(:irq_r, 1)

      rq_v = reg(:rq_v, 1)
      rq_data = reg(:rq_data, 256)
      rq_wr = reg(:rq_wr, 1)

      # -- RC: stage 0
      r0v = reg(:r0v, 1)
      r0d = reg(:r0d, 256)
      r0l = reg(:r0l, 1)
      r0f = reg(:r0f, 1)
      in_pkt = reg(:in_pkt, 1)
      cap_pend = reg(:cap_pend, 1)
      cap_lo = reg(:cap_lo, 160)

      sync do
        r0v <~ rc_v

        if rc_v do
          r0d <~ rc_d
          r0l <~ rc_l
          r0f <~ not in_pkt
          in_pkt <~ not rc_l
        end
      end

      # -- RC: stage 1, the two beats of a 32-byte completion (payload starts at DWord 3)
      mine =
        wire(:mine, r0d[64..71] == cat([const(1, 1), gen, const(0, 2), const(ch, 1)]))

      cpl_bad =
        wire(
          :cpl_bad,
          r0d[43..45] != 0 or r0d[46] or r0d[12..15] != 0 or r0d[16..28] != 32 or
            r0d[32..42] != 8 or r0l
        )

      first_ok = wire(:first_ok, r0v and r0f and mine and f_busy)
      second = wire(:second, r0v and not r0f and cap_pend)
      full = wire(:full, cat([r0d[0..95], cap_lo]))
      l_addr = wire(:l_addr, full[0..63])
      l_len = wire(:l_len, full[64..95])
      l_flags = wire(:l_flags, full[96..127])

      l_ok =
        wire(
          :l_ok,
          l_addr[0..4] == 0 and l_len[0..4] == 0 and l_len != 0 and l_len[28..31] == 0
        )

      land_ok = wire(:land_ok, second and l_ok)
      land_bad = wire(:land_bad, second and not l_ok)
      fail = wire(:fail, first_ok and cpl_bad)

      # -- queue towards the engine
      pop = wire(:pop, d_next and o_valid)
      to_o = wire(:to_o, land_ok and (not o_valid or (pop and not n_valid)))
      to_n = wire(:to_n, land_ok and o_valid and not pop)

      # -- fetch timeout
      tmo_hit =
        wire(:tmo_hit, f_busy and tmo_in != 0 and add_wrap(f_tmo, 1) == tmo_in)

      # -- write-back packets
      tail_next =
        wire(:tail_next, mux(add_wrap(tail, 1) == dsize, const(0, 16), add_wrap(tail, 1)))

      cnt_next = wire(:cnt_next, add_wrap(cnt, 1))
      ent_addr = wire(:ent_addr, add_wrap(dbase, zext(cat([tail, const(0, 5)]), 64)))
      fet_addr = wire(:fet_addr, add_wrap(dbase, zext(cat([fidx, const(0, 5)]), 64)))

      st_dsc =
        Util.desc(:rq, %{
          address: add_wrap(ent_addr, const(24, 64)),
          dw_count: 2,
          req_type: :mem_write
        })

      st_word = cat([const(0, 29), ev_eop, ev_err, const(1, 1)])

      hd_dsc =
        Util.desc(:rq, %{
          address: cat([wb_addr[3..63], const(0, 3)]),
          dw_count: 2,
          req_type: :mem_write
        })

      fe_dsc =
        Util.desc(:rq, %{
          address: fet_addr,
          dw_count: 8,
          req_type: :mem_read,
          tag: cat([const(1, 1), gen, const(0, 2), const(ch, 1)])
        })

      abort = fn ->
        if not active, do: goto(:idle)
      end

      f =
        fsm :wb, reset: :idle do
          state :idle do
            if ev_valid do
              if wb_desc,
                do: goto(:w_desc),
                else: if(wb_head, do: goto(:w_head), else: goto(:fin))
            end

            abort.()
          end

          state :w_desc do
            if not tx_busy, do: goto(:w_desc_wait)

            abort.()
          end

          state :w_desc_wait do
            if done, do: if(wb_head, do: goto(:w_head), else: goto(:fin))
            abort.()
          end

          state :w_head do
            if not tx_busy, do: goto(:w_head_wait)

            abort.()
          end

          state :w_head_wait do
            if done, do: goto(:fin)
            abort.()
          end

          state :fin do
            goto(:idle)
            abort.()
          end
        end

      fin = wire(:fin_w, in_state(f, :fin))
      send_st = wire(:send_st, in_state(f, :w_desc) and not tx_busy)
      send_hd = wire(:send_hd, in_state(f, :w_head) and not tx_busy)

      can_fetch =
        wire(
          :can_fetch,
          active and not halted and not f_busy and head != fidx and not (o_valid and n_valid) and
            not tx_busy and not ev_valid and not in_state(f, :w_desc) and
            not in_state(f, :w_head)
        )

      rq.tdata <~ rq_data
      rq.tkeep <~ mux(rq_wr, const(0x3F, 8), const(0x0F, 8))
      rq.tlast <~ 1
      rq.tuser <~ 0xFF
      rq.tvalid <~ rq_v

      sync do
        if rq.tready, do: rq_v <~ 0
        if done, do: tx_busy <~ 0

        if send_st do
          rq_v <~ 1
          rq_data <~ cat([cat([const(0, 64), ev_len, st_word]), st_dsc])
          rq_wr <~ 1
          tx_busy <~ 1
        end

        if send_hd do
          rq_v <~ 1
          rq_data <~ cat([cat([const(0, 64), cnt_next, zext(tail_next, 32)]), hd_dsc])
          rq_wr <~ 1
          tx_busy <~ 1
        end

        if can_fetch do
          rq_v <~ 1
          rq_data <~ cat([const(0, 128), fe_dsc])
          rq_wr <~ 0
          tx_busy <~ 1
          f_busy <~ 1
          f_tmo <~ 0
          fidx <~ mux(add_wrap(fidx, 1) == dsize, const(0, 16), add_wrap(fidx, 1))
        end

        if f_busy, do: f_tmo <~ add_wrap(f_tmo, 1)

        if pop do
          if n_valid do
            o_addr <~ n_addr
            o_len <~ n_len
            o_irq <~ n_irq
            o_stop <~ n_stop
            n_valid <~ 0
          else
            o_valid <~ 0
          end
        end

        if to_o do
          o_valid <~ 1
          o_addr <~ l_addr
          o_len <~ l_len[0..27]
          o_irq <~ l_flags[0]
          o_stop <~ l_flags[1]
        end

        if to_n do
          n_valid <~ 1
          n_addr <~ l_addr
          n_len <~ l_len[0..27]
          n_irq <~ l_flags[0]
          n_stop <~ l_flags[1]
        end

        if first_ok and not cpl_bad, do: cap_lo <~ r0d[96..255]
        if first_ok and not cpl_bad, do: cap_pend <~ 1
        if second, do: cap_pend <~ 0
        if land_ok, do: f_busy <~ 0

        if fail or land_bad or tmo_hit do
          halted <~ 1
          f_busy <~ 0
        end

        if fail or tmo_hit, do: ferr <~ 1
        if land_bad, do: bad <~ 1

        if cmp_v do
          ev_valid <~ 1
          ev_len <~ cmp_len
          ev_err <~ cmp_err
          ev_eop <~ cmp_eop
          ev_irq <~ cmp_irq
        end

        irq_r <~ (fin and ev_irq and irq_en)

        if fin do
          ev_valid <~ 0
          tail <~ tail_next
          cnt <~ cnt_next
        end

        if not active do
          fidx <~ 0
          tail <~ 0
          cnt <~ 0
          halted <~ 0
          bad <~ 0
          ferr <~ 0
          f_busy <~ 0
          tx_busy <~ 0
          o_valid <~ 0
          n_valid <~ 0
          ev_valid <~ 0
          cap_pend <~ 0
          rq_v <~ 0
        end
      end

      d_valid_o <~ o_valid
      d_addr_o <~ o_addr
      d_len_o <~ zext(o_len, 32)
      d_irq_o <~ o_irq
      if stop, do: d_stop_o <~ o_stop
      busy_o <~ ev_valid
      irq_o <~ irq_r
      tail_o <~ tail
      count_o <~ cnt
      fetch_o <~ fidx
      stat_o <~ cat([ferr, bad, halted])
    end
  end
end
