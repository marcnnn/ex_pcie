defmodule ExPcie.RTL.Bar0Bridge do
  @moduledoc """
  BAR0 completer: the PCIE4C CQ/CC interfaces to an AXI4-Lite master.

  Ports: `cq` (slave stream), `cc` (master stream), `cq_np_req` (u2,
  non-posted request credit), `m_axil` (AXI4-Lite master, `addr_bits`
  address bits, 32-bit data) and the counters `ur_count`, `drop_count`,
  `axil_err_count` (16 bits, saturating at wrap-around is not handled).

  Behaviour, one request at a time (so reads see earlier writes):

    * memory write to BAR 0, 1 to 4 DWords: one AXI4-Lite write per DWord
      (`wstrb` from `first_be`, `last_be`, all ones between); no completion;
      an AXI error response only increments `axil_err_count`
    * memory read from BAR 0, 1 to 4 DWords: one AXI4-Lite read per DWord,
      then a single CplD with `byte_count` and `lower_address` computed
      from the byte enables; an AXI error response turns the completion
      into a Cpl with Completer Abort (status 4)
    * any other non-posted request (I/O, atomics, locked read, reads of
      another BAR, longer than 4 DWords, poisoned): Cpl with Unsupported
      Request (status 1, no data, byte count 4); `ur_count` increments
    * any other posted request (writes to another BAR, messages, long or
      poisoned writes) and packets with `discontinue` are dropped and
      counted in `drop_count`
    * `cq_np_req` is pulsed to keep up to four non-posted credits with the
      core

  The BAR offset is the low `addr_bits` bits of the request address, so
  the BAR aperture in the core must be at least `2^addr_bits`.
  Assumes 256-bit streams. `ExPcie.Model.Core` is the reference model.
  """
  use ExHdl.RTL
  alias ExPcie.RTL.{Ifc, Util}

  def build(opts \\ []) do
    ab = Keyword.get(opts, :addr_bits, 20)
    bar = Keyword.get(opts, :bar_id, 0)

    module "pcie_bar0_bridge_#{ab}_#{bar}" do
      cq = slave(:cq, Ifc.cq())
      cc = master(:cc, Ifc.cc())
      axl = master(:m_axil, Interface.axi_lite(addr: ab, data: 32))
      np_req = output(:cq_np_req, 2)
      ur_count_o = output(:ur_count, 16)
      drop_count_o = output(:drop_count, 16)
      err_count_o = output(:axil_err_count, 16)

      # -- state
      addr = reg(:addr, ab)
      idx = reg(:idx, 3)
      n = reg(:n, 3)
      fbe = reg(:fbe, 4)
      lbe = reg(:lbe, 4)
      rid = reg(:rid, 16)
      tag = reg(:tag, 8)
      tc = reg(:tc, 3)
      attr = reg(:attr, 3)
      d = for i <- 0..3, do: reg(:"d#{i}", 32)
      ur_flag = reg(:ur_flag, 1)
      err = reg(:err, 1)
      credit = reg(:credit, 3)
      ur_count = reg(:ur_count_r, 16)
      drop_count = reg(:drop_count_r, 16)
      err_count = reg(:err_count_r, 16)

      awvalid = reg(:awvalid_r, 1)
      wvalid = reg(:wvalid_r, 1)
      arvalid = reg(:arvalid_r, 1)
      bready = reg(:bready_r, 1)
      rready = reg(:rready_r, 1)
      awaddr = reg(:awaddr_r, ab)
      araddr = reg(:araddr_r, ab)
      wdata = reg(:wdata_r, 32)
      wstrb = reg(:wstrb_r, 4)

      cc_data = reg(:cc_data, 256)
      cc_keep = reg(:cc_keep, 8)
      cc_valid = reg(:cc_valid, 1)

      # -- request decode
      t = cq.tdata
      reqtype = wire(:reqtype, Util.field(:cq, t, :req_type))
      dwcnt = wire(:dwcnt, Util.field(:cq, t, :dw_count))
      bar_ok = wire(:bar_ok, Util.field(:cq, t, :bar_id) == bar)
      poisoned = wire(:poisoned, Util.field(:cq, t, :poisoned))
      u_fbe = wire(:u_fbe, cq.tuser[0..3])
      u_lbe = wire(:u_lbe, cq.tuser[4..7])
      disc = wire(:disc, cq.tuser[41])
      mem_rd = wire(:mem_rd, reqtype == 0)
      mem_wr = wire(:mem_wr, reqtype == 1)
      np = wire(:np, reqtype <= 7 and reqtype != 1)
      len_ok = wire(:len_ok, dwcnt >= 1 and dwcnt <= 4)
      good = wire(:good, bar_ok and not poisoned and len_ok)
      mrd_ok = wire(:mrd_ok, mem_rd and good)
      mwr_ok = wire(:mwr_ok, mem_wr and good)
      ur = wire(:ur, np and not mrd_ok)
      lo_f = wire(:lo_f, Util.lo_off(fbe))
      hi_e = wire(:hi_e, Util.hi_off(mux(n == 1, fbe, lbe)))

      f =
        fsm :ctrl, reset: :idle do
          state :idle do
            if cq.tvalid do
              addr <~ cat([t[2..(ab - 1)], const(0, 2)])
              idx <~ 0
              n <~ trunc(dwcnt, 3)
              fbe <~ u_fbe
              lbe <~ u_lbe
              rid <~ Util.field(:cq, t, :requester_id)
              tag <~ Util.field(:cq, t, :tag)
              tc <~ Util.field(:cq, t, :tc)
              attr <~ Util.field(:cq, t, :attr)
              err <~ 0
              ur_flag <~ (ur and not disc)

              for i <- 0..3, do: d |> Enum.at(i) |> then(&(&1 <~ Util.lane(t, 4 + i)))

              cond_multi = not cq.tlast

              if cond_multi do
                goto(:flush)
              else
                if disc do
                  drop_count <~ add_wrap(drop_count, 1)
                else
                  if mwr_ok do
                    goto(:wr_issue)
                  else
                    if mrd_ok do
                      goto(:rd_issue)
                    else
                      if ur do
                        ur_count <~ add_wrap(ur_count, 1)
                        goto(:cpl_prep)
                      else
                        drop_count <~ add_wrap(drop_count, 1)
                      end
                    end
                  end
                end
              end
            end
          end

          state :flush do
            if cq.tvalid and cq.tlast do
              if ur_flag do
                ur_count <~ add_wrap(ur_count, 1)
                goto(:cpl_prep)
              else
                drop_count <~ add_wrap(drop_count, 1)
                goto(:idle)
              end
            end
          end

          state :wr_issue do
            awvalid <~ 1
            wvalid <~ 1
            awaddr <~ add_wrap(addr, cat([idx, const(0, 2)]))
            wdata <~ mux(idx, d)
            wstrb <~ mux(idx == 0 or idx + 1 != n, mux(idx == 0, fbe, const(15, 4)), lbe)
            goto(:wr_wait)
          end

          state :wr_wait do
            if axl.awready, do: awvalid <~ 0
            if axl.wready, do: wvalid <~ 0

            if (axl.awready or not awvalid) and (axl.wready or not wvalid) do
              bready <~ 1
              goto(:wr_resp)
            end
          end

          state :wr_resp do
            if axl.bvalid do
              bready <~ 0
              if axl.bresp[1], do: err_count <~ add_wrap(err_count, 1)
              idx <~ add_wrap(idx, 1)
              if idx + 1 == n, do: goto(:idle), else: goto(:wr_issue)
            end
          end

          state :rd_issue do
            arvalid <~ 1
            araddr <~ add_wrap(addr, cat([idx, const(0, 2)]))
            goto(:rd_wait)
          end

          state :rd_wait do
            if axl.arready do
              arvalid <~ 0
              rready <~ 1
              goto(:rd_resp)
            end
          end

          state :rd_resp do
            if axl.rvalid do
              rready <~ 0

              switch idx do
                0 -> Enum.at(d, 0) <~ axl.rdata
                1 -> Enum.at(d, 1) <~ axl.rdata
                2 -> Enum.at(d, 2) <~ axl.rdata
                _ -> Enum.at(d, 3) <~ axl.rdata
              end

              if axl.rresp[1] do
                err <~ 1
                err_count <~ add_wrap(err_count, 1)
              end

              idx <~ add_wrap(idx, 1)
              if idx + 1 == n, do: goto(:cpl_prep), else: goto(:rd_issue)
            end
          end

          state :cpl_prep do
            ok = not ur_flag and not err
            status = mux(ur_flag, const(1, 3), mux(err, const(4, 3), const(0, 3)))
            tot = cat([n, const(0, 2)])

            bc_ok = sub_wrap(sub_wrap(tot, zext(lo_f, 5)), zext(hi_e, 5))

            bc_ok = mux(n == 1 and fbe == 0, const(1, 5), bc_ok)
            bc = mux(ok, zext(bc_ok, 13), const(4, 13))
            lower = mux(ok, cat([addr[2..6], lo_f]), const(0, 7))

            dsc =
              Util.desc(:cc, %{
                lower_address: lower,
                byte_count: bc,
                dw_count: mux(ok, zext(n, 11), const(0, 11)),
                status: status,
                requester_id: rid,
                tag: tag,
                tc: tc,
                attr: attr
              })

            cc_data
            <~ cat([
              const(0, 32),
              Enum.at(d, 3),
              Enum.at(d, 2),
              Enum.at(d, 1),
              Enum.at(d, 0),
              dsc
            ])

            cc_keep
            <~ mux(
              ok,
              mux(n, for(i <- 0..7, do: const(Bitwise.bsl(1, min(3 + i, 7)) - 1, 8))),
              const(7, 8)
            )

            cc_valid <~ 1
            goto(:cpl_send)
          end

          state :cpl_send do
            if cc.tready do
              cc_valid <~ 0
              goto(:idle)
            end
          end
        end

      # -- credits for non-posted requests
      take = wire(:take, cq.tvalid and in_state(f, :idle))
      inc = wire(:inc, credit < 4)
      dec = wire(:dec, take and np)

      sync do
        if inc and not dec, do: credit <~ add_wrap(credit, 1)
        if dec and not inc, do: credit <~ sub_wrap(credit, 1)
      end

      np_req <~ zext(inc, 2)
      cq.tready <~ (in_state(f, :idle) or in_state(f, :flush))

      cc.tdata <~ cc_data
      cc.tkeep <~ cc_keep
      cc.tlast <~ 1
      cc.tuser <~ 0
      cc.tvalid <~ cc_valid

      axl.awaddr <~ awaddr
      axl.awprot <~ 0
      axl.awvalid <~ awvalid
      axl.wdata <~ wdata
      axl.wstrb <~ wstrb
      axl.wvalid <~ wvalid
      axl.bready <~ bready
      axl.araddr <~ araddr
      axl.arprot <~ 0
      axl.arvalid <~ arvalid
      axl.rready <~ rready

      ur_count_o <~ ur_count
      drop_count_o <~ drop_count
      err_count_o <~ err_count
    end
  end
end
