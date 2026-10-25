defmodule ExPcie.RTL.C2h do
  @moduledoc """
  Card-to-host DMA channel: an AXI4-Stream into a circular buffer in host
  memory, written with posted memory writes on RQ, one interrupt per
  period.

  Configuration inputs (stable while `run` is high; `run` low resets the
  channel): `base` (64-bit host address, 32-byte aligned), `ring_bytes`
  (multiple of `period_bytes`), `period_bytes` (multiples of 32),
  `cfg_max_payload` (the core's code, 0 = 128 B, 1 = 256 B, 2 = 512 B).

  Stream: `s_axis` (256-bit `tdata`, `tlast`). A packet is one or more
  whole 32-byte beats; `tlast` ends a TLP early (low latency: a sample
  frame group can leave without waiting for a full payload). Without
  `tlast` a TLP carries the maximum payload. TLPs never cross a 4 KiB
  boundary or a period boundary, so the ring needs no further alignment
  and the period interrupt follows exactly the last write of a period.
  The ring is overwritten in a loop; the engine never waits for the host.

  RQ: one packet in flight (`done` from `ExPcie.RTL.RqMux` after its last
  beat left the RQ port releases the next one). Outputs: `rq` master,
  `ptr` (ring offset in bytes of data completed to the RQ port), `irq`
  (one-cycle pulse per completed period), `pkt_count`.

  Descriptor mode (option `desc: true`, selected at run time by the
  `desc_mode` input): the destination is the buffer of the current
  descriptor of an `ExPcie.RTL.DescRing` (`d_valid`, `d_addr`, `d_len`,
  `d_irq`, `d_stop`; `d_next` pops one) instead of the ring; the stream is
  back-pressured while there is none. A TLP also ends at the end of the
  buffer. A descriptor completes when its buffer is full or, with `d_stop`,
  at `tlast`; it is reported on `cmp_valid` (`cmp_len` bytes, `cmp_eop`,
  `cmp_irq`) once the last write of its data was accepted on RQ (`done`),
  which is when the ring unit may write the status. The period interrupt
  and `ptr` are not used in this mode.

  Input side (`s_axis` to a 64-beat buffer) and output side (buffer to
  `rq`, realigned from beat to DWord offset 4 behind the 4-DWord
  descriptor) are independent, so the stream can run ahead by up to the
  buffer.
  """
  use ExHdl.RTL
  alias ExHdl.RTL.Examples
  alias ExPcie.RTL.{Ifc, Util}

  def build(opts \\ []) do
    depth = Keyword.get(opts, :fifo_beats, 64)
    fb = Util.clog2(depth)
    desc = Keyword.get(opts, :desc, false)

    module "pcie_c2h_#{depth}#{if desc, do: "_desc", else: ""}" do
      s = slave(:s_axis, Interface.axi_stream(data: 256, keep: false))
      rq = master(:rq, Ifc.rq())
      run_in = input(:run, 1)
      run_q = reg(:run_q, 1)
      run = wire(:active, run_in and run_q)
      base = input(:base, 64)
      ring = input(:ring_bytes, 32)
      period = input(:period_bytes, 32)
      mps_code = input(:cfg_max_payload, 3)
      done = input(:done, 1)
      ptr_o = output(:ptr, 32)
      irq_o = output(:irq, 1)
      cnt_o = output(:pkt_count, 16)

      # descriptor mode (`desc: true`): buffers come from an `ExPcie.RTL.DescRing`
      {desc_mode, d_valid, d_addr, d_len, d_irq, d_stop, cmp_busy} =
        if desc do
          {input(:desc_mode, 1), input(:d_valid, 1), input(:d_addr, 64), input(:d_len, 32),
           input(:d_irq, 1), input(:d_stop, 1), input(:cmp_busy, 1)}
        else
          {const(0, 1), const(0, 1), const(0, 64), const(0, 32), const(0, 1), const(0, 1),
           const(0, 1)}
        end

      sync do
        run_q <~ run_in
      end

      # -- input side
      wr_ptr = reg(:wr_ptr, fb + 1)
      tail = reg(:tail, fb + 1)
      pk = reg(:pk_beats, 6)
      in_off = reg(:in_off, 32)
      in_pleft = reg(:in_pleft, 32)
      lq = for i <- 0..3, do: reg(:"lq#{i}", 6)
      lqa = for i <- 0..3, do: reg(:"lqa#{i}", 64)
      lqe = for i <- 0..3, do: reg(:"lqe#{i}", 1)
      lqp = for i <- 0..3, do: reg(:"lqp#{i}", 1)
      lqi = for i <- 0..3, do: reg(:"lqi#{i}", 1)
      cd_valid = reg(:cd_valid, 1)
      cd_addr = reg(:cd_addr, 64)
      cd_left = reg(:cd_left, 32)
      cd_stop = reg(:cd_stop, 1)
      cd_irq = reg(:cd_irq, 1)
      tlp_addr = reg(:tlp_addr, 64)
      lq_wp = reg(:lq_wp, 3)
      lq_rp = reg(:lq_rp, 3)

      mem = memory(:fifo, width: 256, depth: depth, style: Keyword.get(opts, :style, :auto))

      lq_count = wire(:lq_count, sub_wrap(lq_wp, lq_rp))
      full = wire(:full, sub_wrap(wr_ptr, tail) == depth)
      s.tready <~ (run and not full and lq_count < 4 and (not desc_mode or cd_valid))
      accept = wire(:accept, s.tvalid and s.tready)

      mps_beats =
        wire(
          :mps_beats,
          mux(mps_code[0..1], [const(4, 6), const(8, 6), const(16, 6), const(32, 6)])
        )

      load = wire(:load, run and desc_mode and d_valid and not cd_valid)

      a12 =
        wire(
          :a12,
          mux(desc_mode, cd_addr[0..11], add_wrap(base[0..11], in_off[0..11]))
        )

      end_in = wire(:end_in, desc_mode and (cd_left == 32 or (s.tlast and cd_stop)))
      to4k = wire(:to4k, sub_wrap(const(128, 8), zext(a12[5..11], 8)))
      mps_rem = wire(:mps_rem, sub_wrap(mps_beats, pk))

      last_in_pkt =
        wire(
          :last_in_pkt,
          s.tlast or mps_rem == 1 or to4k == 1 or (not desc_mode and in_pleft[5..31] == 1) or
            end_in
        )

      write_port(mem, addr: wr_ptr[0..(fb - 1)], data: s.tdata, en: accept)
      lq_push = wire(:lq_push, accept and last_in_pkt)

      sync do
        if accept do
          wr_ptr <~ add_wrap(wr_ptr, 1)
          in_off <~ mux(add_wrap(in_off, 32) == ring, const(0, 32), add_wrap(in_off, 32))
          in_pleft <~ mux(in_pleft == 32, period, sub_wrap(in_pleft, 32))
          pk <~ mux(last_in_pkt, const(0, 6), add_wrap(pk, 1))
          cd_addr <~ add_wrap(cd_addr, const(32, 64))
          cd_left <~ sub_wrap(cd_left, const(32, 32))
          if pk == 0, do: tlp_addr <~ cd_addr
          if end_in, do: cd_valid <~ 0
        end

        if load do
          cd_valid <~ 1
          cd_addr <~ d_addr
          cd_left <~ d_len
          cd_stop <~ d_stop
          cd_irq <~ d_irq
        end

        if lq_push do
          for i <- 0..3 do
            if lq_wp[0..1] == i do
              Enum.at(lq, i) <~ add_wrap(pk, 1)
              Enum.at(lqa, i) <~ mux(pk == 0, cd_addr, tlp_addr)
              Enum.at(lqe, i) <~ end_in
              Enum.at(lqp, i) <~ (end_in and s.tlast and cd_stop)
              Enum.at(lqi, i) <~ cd_irq
            end
          end

          lq_wp <~ add_wrap(lq_wp, 1)
        end

        if not run do
          wr_ptr <~ 0
          pk <~ 0
          in_off <~ 0
          in_pleft <~ period
          lq_wp <~ 0
          cd_valid <~ 0
        end
      end

      # -- output side
      tx_addr = reg(:tx_addr, 64)
      tx_off = reg(:tx_off, 32)
      tx_pleft = reg(:tx_pleft, 32)
      rp = reg(:rp, fb + 1)
      k = reg(:k, 6)
      n_tx = reg(:n_tx, 6)
      prev_hi = reg(:prev_hi, 128)
      irq = reg(:irq_r, 1)
      count = reg(:count, 16)
      cur_addr = reg(:cur_addr, 64)
      cur_end = reg(:cur_end, 1)
      cur_eop = reg(:cur_eop, 1)
      cur_irq = reg(:cur_irq, 1)
      acc_len = reg(:acc_len, 32)

      sk = instance(:sk, Examples.skid_buffer(Ifc.rq()))
      connect(sk.m_axis, rq)

      ren = wire(:ren, 1)
      rd_data = read_port(mem, addr: rp[0..(fb - 1)], en: ren)

      bytes = wire(:bytes, cat([n_tx, const(0, 5)]))
      cmp_len_w = wire(:cmp_len_w, add_wrap(acc_len, zext(bytes, 32)))
      last_beat = wire(:last_beat, k == n_tx)

      dsc =
        Util.desc(:rq, %{
          address: mux(desc_mode, cur_addr, tx_addr),
          dw_count: cat([n_tx, const(0, 3)]),
          req_type: :mem_write
        })

      abort = fn ->
        if not run do
          tx_off <~ 0
          tx_addr <~ base
          tx_pleft <~ period
          rp <~ 0
          tail <~ 0
          lq_rp <~ 0
          acc_len <~ 0
          goto(:idle)
        end
      end

      f =
        fsm :tx, reset: :idle do
          state :idle do
            if lq_count > 0 and (not desc_mode or not mux(lq_rp[0..1], lqe) or not cmp_busy) do
              n_tx <~ mux(lq_rp[0..1], lq)
              cur_addr <~ mux(lq_rp[0..1], lqa)
              cur_end <~ mux(lq_rp[0..1], lqe)
              cur_eop <~ mux(lq_rp[0..1], lqp)
              cur_irq <~ mux(lq_rp[0..1], lqi)
              k <~ 0
              goto(:prime)
            end

            abort.()
          end

          state :prime do
            rp <~ add_wrap(rp, 1)
            goto(:stream)
            abort.()
          end

          state :stream do
            if sk.s_axis.tready do
              prev_hi <~ rd_data[128..255]
              k <~ add_wrap(k, 1)
              if k + 1 < n_tx, do: rp <~ add_wrap(rp, 1)
              if last_beat, do: goto(:wait_done)
            end

            abort.()
          end

          state :wait_done do
            if done do
              tail <~ rp
              lq_rp <~ add_wrap(lq_rp, 1)
              acc_len <~ mux(cur_end, const(0, 32), cmp_len_w)

              tx_off
              <~ mux(
                add_wrap(tx_off, zext(bytes, 32)) == ring,
                const(0, 32),
                add_wrap(tx_off, zext(bytes, 32))
              )

              tx_addr
              <~ mux(
                add_wrap(tx_off, zext(bytes, 32)) == ring,
                base,
                add_wrap(tx_addr, zext(bytes, 64))
              )

              tx_pleft
              <~ mux(tx_pleft == zext(bytes, 32), period, sub_wrap(tx_pleft, zext(bytes, 32)))

              goto(:idle)
            end

            abort.()
          end
        end

      in_stream = wire(:in_stream, in_state(f, :stream))
      ren <~ (in_state(f, :prime) or (in_stream and sk.s_axis.tready and k + 1 < n_tx))
      done_ev = wire(:done_ev, in_state(f, :wait_done) and done)

      sk.s_axis.tvalid <~ in_stream

      sk.s_axis.tdata
      <~ cat([mux(last_beat, const(0, 128), rd_data[0..127]), mux(k == 0, dsc, prev_hi)])

      sk.s_axis.tkeep <~ mux(last_beat, const(0x0F, 8), const(0xFF, 8))
      sk.s_axis.tlast <~ last_beat
      sk.s_axis.tuser <~ mux(k == 0, const(0xFF, 62), const(0, 62))

      sync do
        irq <~ (done_ev and tx_pleft == zext(bytes, 32) and not desc_mode)
        if done_ev, do: count <~ add_wrap(count, 1)
        if not run, do: count <~ 0
      end

      if desc do
        output(:d_next, 1) <~ load
        output(:cmp_valid, 1) <~ (done_ev and desc_mode and cur_end)
        output(:cmp_len, 32) <~ cmp_len_w
        output(:cmp_err, 1) <~ 0
        output(:cmp_eop, 1) <~ cur_eop
        output(:cmp_irq, 1) <~ cur_irq
      end

      ptr_o <~ tx_off
      irq_o <~ irq
      cnt_o <~ count
    end
  end
end
