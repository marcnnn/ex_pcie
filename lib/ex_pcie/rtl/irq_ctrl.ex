defmodule ExPcie.RTL.IrqCtrl do
  @moduledoc """
  Interrupt requests to the core's MSI-X or MSI interface.

  Inputs: `req` (`vectors` bits, a pulse raises a vector), the MSI-X table
  as flat vectors `tbl_addr` (64 bits per vector), `tbl_data` (32 bits per
  vector), `tbl_mask` (one bit per vector, the table's vector control
  mask), and the core's `cfg_msix_enable`, `cfg_msix_mask` (function
  mask), `cfg_msi_enable`, `cfg_msix_sent`, `cfg_msix_fail`,
  `cfg_msi_sent`, `cfg_msi_fail`.

  Outputs: `cfg_msix_int` (one-cycle pulse) with `cfg_msix_address` and
  `cfg_msix_data` from the table, or `cfg_msi_int` (32-bit one-hot, one
  cycle) in MSI mode; `pending` (one bit per vector, for the pending bit
  array) and `cfg_msi_pending_status`.

  A vector stays pending until the core answers `sent`; on `fail` the
  request is repeated. Masked vectors (table mask or function mask in
  MSI-X mode) stay pending and fire after unmasking. One request is in
  flight at a time, lowest vector first. With neither MSI-X nor MSI
  enabled nothing is sent (legacy INTx is not supported). There is no
  timeout for a core that never answers.
  """
  use ExHdl.RTL

  def build(opts \\ []) do
    n = Keyword.get(opts, :vectors, 2)
    vb = max(ExHdl.RTL.Builder.ceil_log2(n), 1)

    module "pcie_irq_ctrl_#{n}" do
      req = input(:req, n)
      tbl_addr = input(:tbl_addr, 64 * n)
      tbl_data = input(:tbl_data, 32 * n)
      tbl_mask = input(:tbl_mask, n)
      msix_en = input(:cfg_msix_enable, 1)
      msix_fm = input(:cfg_msix_mask, 1)
      msi_en = input(:cfg_msi_enable, 1)
      msix_sent = input(:cfg_msix_sent, 1)
      msix_fail = input(:cfg_msix_fail, 1)
      msi_sent = input(:cfg_msi_sent, 1)
      msi_fail = input(:cfg_msi_fail, 1)
      msix_int = output(:cfg_msix_int, 1)
      msix_a = output(:cfg_msix_address, 64)
      msix_d = output(:cfg_msix_data, 32)
      msi_int = output(:cfg_msi_int, 32)
      msi_pend = output(:cfg_msi_pending_status, 32)
      pend_o = output(:pending, n)

      pending = reg(:pending_r, n)
      vec = reg(:vec, vb)

      sendable = wire(:sendable, mux(msix_en, pending &&& ~~~tbl_mask, pending))
      sendable_ok = wire(:sendable_ok, mux(msix_en, not msix_fm, msi_en))
      any = wire(:any, reduce_or(sendable) and sendable_ok)

      first =
        Enum.reduce((n - 1)..0//-1, const(0, vb), fn i, acc ->
          mux(sendable[i], const(i, vb), acc)
        end)

      f =
        fsm :irq, reset: :idle do
          state :idle do
            if any do
              vec <~ first
              goto(:fire)
            end
          end

          state :fire do
            goto(:wait)
          end

          state :wait do
            if (msix_en and (msix_sent or msix_fail)) or (not msix_en and (msi_sent or msi_fail)) do
              goto(:idle)
            end
          end
        end

      fire = wire(:fire_w, in_state(f, :fire))

      ok =
        wire(
          :ok_w,
          in_state(f, :wait) and ((msix_en and msix_sent) or (not msix_en and msi_sent))
        )

      clear =
        wire(
          :clear_w,
          mux(ok, mux(vec, for(i <- 0..(n - 1), do: const(Bitwise.bsl(1, i), n))), const(0, n))
        )

      sync do
        pending <~ ((pending &&& ~~~clear) ||| req)
      end

      msix_int <~ (fire and msix_en)
      msix_a <~ mux(vec, for(i <- 0..(n - 1), do: tbl_addr[(64 * i)..(64 * i + 63)]))
      msix_d <~ mux(vec, for(i <- 0..(n - 1), do: tbl_data[(32 * i)..(32 * i + 31)]))

      msi_int
      <~ mux(
        fire and not msix_en and msi_en,
        mux(vec, for(i <- 0..(n - 1), do: const(Bitwise.bsl(1, i), 32))),
        const(0, 32)
      )

      msi_pend <~ zext(pending, 32)
      pend_o <~ pending
    end
  end
end
