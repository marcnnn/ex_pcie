defmodule ExPcie.Test.MixerRegs do
  @moduledoc "A `defregs` slave standing in for the audio mixer behind the endpoint's BAR0."
  use ExHdl.Regs

  defregs "test_mixer_regs", addr_width: 12 do
    register :ctrl do
      field :enable, 0, :rw, reset: 1
      field :mode, 1..2, :rw, enum: [off: 0, mono: 1, stereo: 2]
    end

    register :irq do
      field :overflow, 0, :w1c
    end

    register :gain, count: 4 do
      field :value, 0..15, :rw, reset: 0x4000
    end
  end
end

defmodule ExPcie.Test.PtpRegs do
  @moduledoc "A second `defregs` slave (PTP time readout and an adjustment word)."
  use ExHdl.Regs

  defregs "test_ptp_regs", addr_width: 8 do
    register :time_lo do
      field :value, 0..31, :ro
    end

    register :adj, strobe: :write do
      field :ppb, 0..31, :rw
    end
  end
end
