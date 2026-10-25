defmodule ExPcie.Test.RingEngine do
  @moduledoc """
  Stand-in for a data engine behind `ExPcie.RTL.DescRing`: pops every
  descriptor as soon as it is offered, reports it complete `delay` cycles
  later (when the ring unit can take a report), and counts interrupts.
  """
  @behaviour ExPcie.Model.Agent
  defstruct delay: 5,
            ready: false,
            popped: false,
            block: false,
            busy: false,
            consumed: [],
            pending: [],
            irqs: 0,
            fired: 0,
            cycle: 0,
            err: 0

  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @doc "Descriptors popped so far as `%{addr, len, irq, stop}`, oldest first."
  def consumed(s), do: Enum.reverse(s.consumed)

  @impl true
  def drive(s, cycle) do
    pop = s.ready and not s.popped

    {fire, s} =
      case s.pending do
        [{due, d} | rest] when due <= cycle and not s.busy and not s.block ->
          {d, %{s | pending: rest, block: true, fired: s.fired + 1}}

        _ ->
          {nil, %{s | block: false}}
      end

    ins = %{
      d_next: if(pop, do: 1, else: 0),
      cmp_valid: if(fire, do: 1, else: 0),
      cmp_len: if(fire, do: fire.len, else: 0),
      cmp_irq: if(fire && fire.irq, do: 1, else: 0),
      cmp_eop: 0,
      cmp_err: s.err
    }

    {ins, %{s | popped: pop, ready: s.ready and not pop}}
  end

  @impl true
  def sample(s, outs, cycle) do
    s = %{s | busy: outs.cmp_busy == 1, irqs: s.irqs + outs.irq, cycle: cycle}

    if s.popped do
      d = %{
        addr: outs.d_addr,
        len: outs.d_len,
        irq: outs.d_irq == 1,
        stop: outs.d_stop == 1
      }

      %{
        s
        | consumed: [d | s.consumed],
          pending: s.pending ++ [{cycle + s.delay, d}],
          popped: false
      }
    else
      %{s | ready: outs.d_valid == 1}
    end
  end
end
