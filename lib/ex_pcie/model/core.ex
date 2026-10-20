defmodule ExPcie.Model.Core do
  @moduledoc """
  BEAM model of the PCIE4C hard block as seen from the user logic, plus
  the host behind it: an `ExPcie.Model.Agent` that drives the CQ and RC
  streams and the configuration inputs of a design, and consumes its CC
  and RQ streams and interrupt requests.

  ## Host side

    * `mmio_write/4`, `mmio_read/4`, `cq_raw/3` queue host requests on CQ.
      `mmio_result/2` returns the completion of a read once it came back on
      CC. Non-posted requests wait for a credit from the design
      (`cq_np_req`), at most 32 are held.
    * Host memory (`ExPcie.Model.HostMem`) is read by RQ memory reads and
      written by RQ memory writes; `mem/1`, `put_mem/3`, `read_mem/3`.

  ## Hard block behaviour modelled

    * RQ memory writes are applied to host memory when the last beat is
      accepted. RQ memory reads are split into completions at RCB
      boundaries (`cuts: :random | :all | :none`), each at most `mps`
      bytes, delivered on RC with random latency (`latency: {min, max}`
      cycles, per request plus a few cycles per further completion).
      Completions of one request stay in order; different requests are
      reordered at random with `reorder: true`.
    * Interrupts: a pulse on `cfg_msix_int` (or a bit on `cfg_msi_int`)
      while the matching enable input is set is answered with `*_sent` one
      to four cycles later, or with `*_fail` (`irq_fail:` probability) in
      which case the design must retry. Each delivered interrupt is
      appended to `irq_log/1` after all previously accepted RQ writes
      (the posted-write ordering of the real core), and `on_irq:` (a
      function of `core` and the entry) runs at that point.
    * Random `tvalid` gaps (`cq_valid:`, `rc_valid:` probabilities) and
      `tready` stalls (`cc_ready:`, `rq_ready:`).

  ## Checks (collected in `errors/1`)

  RQ packets must be well formed (`ExPcie.Axis`), memory read or write,
  at most `mps` (writes) or `mrrs` (reads) bytes, not cross a 4 KiB
  boundary, have consistent byte enables, and reads must not reuse a tag
  still outstanding or exceed `max_tags` outstanding. CC packets must be
  well formed and match an outstanding host read. A second interrupt
  request while one is pending is an error.

  The assumptions about PG213 behaviour are listed in `ExPcie.Axis`.
  """
  @behaviour ExPcie.Model.Agent
  import Bitwise

  alias ExPcie.{Axis, TLP}
  alias ExPcie.Model.HostMem

  defstruct cfg: %{},
            rng: nil,
            mem: %{},
            cq_q: [],
            cq_cur: [],
            cq_hold: false,
            cq_np_cur: false,
            np_credits: 0,
            cc_acc: [],
            cc_ready_now: false,
            mmio: %{},
            mmio_next_tag: 0,
            rq_acc: [],
            rq_log: [],
            rq_ready_now: false,
            outstanding: %{},
            rc_reqs: [],
            rc_cur: [],
            rc_cur_tag: nil,
            rc_hold: false,
            irq_req: nil,
            irq_sent: 0,
            irq_fail: 0,
            irq_log: [],
            errors: [],
            stats: %{rq_writes: 0, rq_reads: 0, completions: 0, rc_beats: 0, interrupts: 0},
            cycle: 0

  @defaults %{
    mps: 128,
    mrrs: 512,
    rcb: 64,
    max_tags: 32,
    requester_id: 0x0100,
    completer_id: 0x0000,
    msix_enable: true,
    msi_enable: false,
    msix_mask: false,
    cuts: :random,
    reorder: true,
    latency: {4, 20},
    cq_valid: 1.0,
    rc_valid: 1.0,
    cc_ready: 1.0,
    rq_ready: 1.0,
    irq_fail: 0.0,
    irq_latency: {1, 4},
    on_irq: nil,
    mem_read: nil,
    mem_write: nil,
    bar_aperture: 20,
    error_reads: []
  }

  @doc """
  New model. Options (defaults in brackets): `mps` (128), `mrrs` (512),
  `rcb` (64), `max_tags` (32), `requester_id`, `completer_id`,
  `msix_enable` (true), `msi_enable` (false), `msix_mask`, `cuts`,
  `reorder`, `latency`, `cq_valid`, `rc_valid`, `cc_ready`, `rq_ready`,
  `irq_fail`, `irq_latency`, `on_irq`, `mem_read`, `mem_write`, `bar_aperture`, `error_reads`
  (host addresses whose reads complete with Unsupported Request), `seed`.
  """
  def new(opts \\ []) do
    cfg = Map.merge(@defaults, Map.new(Keyword.delete(opts, :seed)))

    %__MODULE__{
      cfg: cfg,
      rng: :rand.seed_s(:exsss, {Keyword.get(opts, :seed, 1), 31, 32})
    }
  end

  # -- host API --------------------------------------------------------------------------

  def mem(%__MODULE__{mem: m}), do: m
  def put_mem(%__MODULE__{} = c, addr, bin), do: elem(mem_write(c, addr, bin), 0)
  def read_mem(%__MODULE__{} = c, addr, len), do: elem(mem_read(c, addr, len), 1)

  # Host memory is the internal sparse memory unless `mem_read:` and `mem_write:` (functions
  # `(address, length) -> {:ok, binary} | {:error, reason}` and `(address, binary) -> :ok |
  # {:error, reason}`) are configured, e.g. to reach DMA buffers of a mock device. Failed
  # accesses are recorded in `errors/1`; reads then return zeros.
  defp mem_read(%{cfg: %{mem_read: f}} = c, addr, len) when is_function(f, 2) do
    case f.(addr, len) do
      {:ok, bin} -> {c, bin}
      {:error, r} -> {err(c, {:dma_read_fault, addr, len, r}), :binary.copy(<<0>>, len)}
    end
  end

  defp mem_read(c, addr, len), do: {c, HostMem.read(c.mem, addr, len)}

  defp mem_write(%{cfg: %{mem_write: f}} = c, addr, bin) when is_function(f, 2) do
    case f.(addr, bin) do
      :ok -> {c, :ok}
      {:error, r} -> {err(c, {:dma_write_fault, addr, byte_size(bin), r}), :error}
    end
  end

  defp mem_write(c, addr, bin), do: {%{c | mem: HostMem.write(c.mem, addr, bin)}, :ok}
  def errors(%__MODULE__{errors: e}), do: Enum.reverse(e)
  def irq_log(%__MODULE__{irq_log: l}), do: Enum.reverse(l)

  @doc "Every memory request accepted on RQ so far as `%ExPcie.TLP{}`, oldest first."
  def rq_log(%__MODULE__{rq_log: l}), do: Enum.reverse(l)
  def stats(%__MODULE__{stats: s}), do: s
  def set(%__MODULE__{} = c, key, value), do: %{c | cfg: Map.put(c.cfg, key, value)}

  @doc "Queues a 32-bit MMIO write (or a wider one, `data` a binary of whole DWords) to BAR 0."
  def mmio_write(%__MODULE__{} = c, offset, data, opts \\ []) do
    data = if is_integer(data), do: <<data::little-32>>, else: data
    n = div(byte_size(data), 4)

    tlp = %TLP{
      kind: :mwr,
      address: offset,
      length_dw: n,
      data: data,
      requester_id: 0x0010,
      first_be: Keyword.get(opts, :first_be, 0xF),
      last_be: Keyword.get(opts, :last_be, if(n == 1, do: 0, else: 0xF))
    }

    cq_raw(c, tlp, opts)
  end

  @doc "Queues a BAR 0 read of `len_dw` DWords; returns `{core, tag}`."
  def mmio_read(%__MODULE__{} = c, offset, len_dw \\ 1, opts \\ []) do
    tag = c.mmio_next_tag
    first = Keyword.get(opts, :first_be, 0xF)
    last = Keyword.get(opts, :last_be, if(len_dw == 1, do: 0, else: 0xF))

    tlp = %TLP{
      kind: :mrd,
      address: offset,
      length_dw: len_dw,
      requester_id: 0x0010,
      tag: tag,
      first_be: first,
      last_be: last
    }

    c = %{c | mmio_next_tag: rem(tag + 1, 256), mmio: Map.put(c.mmio, tag, :pending)}
    {cq_raw(c, tlp, opts), tag}
  end

  @doc "Result of a host read: `:pending`, `{:ok, binary, cpl}` or `{:error, status, cpl}`."
  def mmio_result(%__MODULE__{mmio: m}, tag), do: Map.get(m, tag)

  @doc "Queues a memory request TLP on CQ with `Axis.cq_beats/2` options (`bar_id:` ...)."
  def cq_raw(%__MODULE__{} = c, %TLP{} = tlp, opts \\ []) do
    beats = Axis.cq_beats(tlp, Keyword.put_new(opts, :bar_aperture, c.cfg.bar_aperture))
    cq_beats(c, beats, tlp.kind == :mrd)
  end

  @doc "Queues pre-built CQ beats; `np` marks a non-posted request."
  def cq_beats(%__MODULE__{} = c, beats, np), do: %{c | cq_q: c.cq_q ++ [{np, beats}]}

  @doc "True when nothing is queued, in flight or waiting for a completion."
  def idle?(%__MODULE__{} = c),
    do:
      c.cq_q == [] and c.cq_cur == [] and c.rc_reqs == [] and c.rc_cur == [] and c.irq_req == nil and
        Enum.all?(c.mmio, fn {_, v} -> v != :pending end)

  # -- agent: drive ----------------------------------------------------------------------

  @impl true
  def drive(%__MODULE__{} = c, _cycle) do
    cfg = c.cfg
    {sent, fail} = {c.irq_sent, c.irq_fail}
    c = %{c | irq_sent: 0, irq_fail: 0}

    {cq_ins, c} = drive_cq(c)
    {rc_ins, c} = drive_rc(c)
    {cc_ready, c} = coin(c, cfg.cc_ready)
    {rq_ready, c} = coin(c, cfg.rq_ready)
    c = %{c | cc_ready_now: cc_ready, rq_ready_now: rq_ready}
    int = fn a -> if a, do: 1, else: 0 end

    ins =
      Map.merge(cq_ins, rc_ins)
      |> Map.merge(%{
        cc_tready: int.(cc_ready),
        rq_tready: int.(rq_ready),
        cfg_max_payload: log2(cfg.mps, 128),
        cfg_max_read_req: log2(cfg.mrrs, 128),
        cfg_msix_enable: int.(cfg.msix_enable),
        cfg_msi_enable: int.(cfg.msi_enable),
        cfg_msix_mask: int.(cfg.msix_mask),
        cfg_msix_sent: bit_of(sent, 1),
        cfg_msix_fail: bit_of(fail, 1),
        cfg_msi_sent: bit_of(sent, 2),
        cfg_msi_fail: bit_of(fail, 2)
      })

    {ins, c}
  end

  defp bit_of(v, k), do: if(v == k, do: 1, else: 0)
  defp log2(v, base), do: v |> div(base) |> :math.log2() |> round()

  defp coin(c, p) do
    {r, rng} = :rand.uniform_s(c.rng)
    {r < p, %{c | rng: rng}}
  end

  defp stream_ins(prefix, nil, valid),
    do: %{
      :"#{prefix}_tdata" => 0,
      :"#{prefix}_tkeep" => 0,
      :"#{prefix}_tlast" => 0,
      :"#{prefix}_tuser" => 0,
      :"#{prefix}_tvalid" => valid
    }

  defp stream_ins(prefix, beat, valid) do
    %{
      :"#{prefix}_tdata" => beat.data,
      :"#{prefix}_tkeep" => beat.keep,
      :"#{prefix}_tlast" => if(beat.last, do: 1, else: 0),
      :"#{prefix}_tuser" => beat.user,
      :"#{prefix}_tvalid" => valid
    }
  end

  defp drive_cq(%{cq_cur: [], cq_q: [{np, beats} | rest]} = c) when not c.cq_hold do
    if not np or c.np_credits > 0,
      do: drive_cq(%{c | cq_cur: beats, cq_q: rest, cq_np_cur: np}),
      else: {stream_ins(:cq, nil, 0), c}
  end

  defp drive_cq(%{cq_cur: []} = c), do: {stream_ins(:cq, nil, 0), %{c | cq_hold: false}}

  defp drive_cq(%{cq_cur: [beat | _]} = c) do
    {gap_ok, c} = coin(c, c.cfg.cq_valid)
    v = c.cq_hold or gap_ok
    {stream_ins(:cq, beat, if(v, do: 1, else: 0)), %{c | cq_hold: v}}
  end

  defp drive_rc(%{rc_cur: [], rc_hold: false} = c) do
    case pick_completion(c) do
      {nil, c} -> {stream_ins(:rc, nil, 0), c}
      {beats, c} -> drive_rc(%{c | rc_cur: beats})
    end
  end

  defp drive_rc(%{rc_cur: []} = c), do: {stream_ins(:rc, nil, 0), %{c | rc_hold: false}}

  defp drive_rc(%{rc_cur: [beat | _]} = c) do
    {gap_ok, c} = coin(c, c.cfg.rc_valid)
    v = c.rc_hold or gap_ok
    {stream_ins(:rc, beat, if(v, do: 1, else: 0)), %{c | rc_hold: v}}
  end

  # one entry of rc_reqs per request: {tag, [{ready_cycle, beats, final?}]}
  defp pick_completion(c) do
    ready = for {{_, [{t, _, _} | _]}, i} <- Enum.with_index(c.rc_reqs), t <= c.cycle, do: i

    case ready do
      [] ->
        {nil, c}

      _ ->
        {i, c} =
          if c.cfg.reorder do
            {r, rng} = :rand.uniform_s(length(ready), c.rng)
            {Enum.at(ready, r - 1), %{c | rng: rng}}
          else
            {hd(ready), c}
          end

        {tag, [{_, beats, final?} | tail]} = Enum.at(c.rc_reqs, i)

        reqs =
          if tail == [],
            do: List.delete_at(c.rc_reqs, i),
            else: List.replace_at(c.rc_reqs, i, {tag, tail})

        {beats, %{c | rc_reqs: reqs, rc_cur_tag: {tag, final?}}}
    end
  end

  # -- agent: sample ---------------------------------------------------------------------

  @impl true
  def sample(%__MODULE__{} = c, outs, cycle) do
    c =
      c
      |> sample_cq(outs)
      |> sample_rc(outs)
      |> sample_cc(outs)
      |> sample_rq(outs)
      |> sample_irq(outs)

    %{c | cycle: cycle + 1}
  end

  defp g(outs, k), do: Map.get(outs, k, 0)

  defp sample_cq(c, outs) do
    c = %{c | np_credits: min(c.np_credits + g(outs, :cq_np_req), 32)}

    if c.cq_hold and g(outs, :cq_tready) == 1 and c.cq_cur != [] do
      [_ | rest] = c.cq_cur
      credits = if c.cq_np_cur == true, do: c.np_credits - 1, else: c.np_credits

      np_state =
        cond do
          rest == [] -> false
          c.cq_np_cur in [true, :started] -> :started
          true -> false
        end

      %{c | cq_cur: rest, cq_hold: false, np_credits: credits, cq_np_cur: np_state}
    else
      c
    end
  end

  defp sample_rc(c, outs) do
    if c.rc_hold and g(outs, :rc_tready) == 1 and c.rc_cur != [] do
      c = %{c | rc_cur: tl(c.rc_cur), rc_hold: false, stats: bump(c.stats, :rc_beats)}

      case c.rc_cur_tag do
        {tag, true} when c.rc_cur == [] ->
          %{c | outstanding: Map.delete(c.outstanding, tag), rc_cur_tag: nil}

        _ ->
          c
      end
    else
      c
    end
  end

  defp bump(stats, k), do: Map.update!(stats, k, &(&1 + 1))
  defp err(c, e), do: %{c | errors: [{c.cycle, e} | c.errors]}

  defp sample_cc(c, outs) do
    if c.cc_ready_now and g(outs, :cc_tvalid) == 1 do
      beat = %{
        data: g(outs, :cc_tdata),
        keep: g(outs, :cc_tkeep),
        last: g(outs, :cc_tlast) == 1,
        user: g(outs, :cc_tuser)
      }

      acc = [beat | c.cc_acc]

      if beat.last do
        finish_cc(%{c | cc_acc: []}, Enum.reverse(acc))
      else
        %{c | cc_acc: acc}
      end
    else
      c
    end
  end

  defp finish_cc(c, beats) do
    case Axis.cc_to_tlp(beats, c.cfg.completer_id) do
      {:ok, tlp} ->
        case c.mmio[tlp.tag] do
          :pending ->
            res =
              if tlp.status == 0 and tlp.kind == :cpld,
                do: {:ok, tlp.data, tlp},
                else: {:error, tlp.status, tlp}

            %{c | mmio: Map.put(c.mmio, tlp.tag, res), stats: bump(c.stats, :completions)}

          _ ->
            err(c, {:unexpected_cc, tlp.tag})
        end

      {:error, reason} ->
        err(c, {:bad_cc, reason})
    end
  end

  defp sample_rq(c, outs) do
    if c.rq_ready_now and g(outs, :rq_tvalid) == 1 do
      beat = %{
        data: g(outs, :rq_tdata),
        keep: g(outs, :rq_tkeep),
        last: g(outs, :rq_tlast) == 1,
        user: g(outs, :rq_tuser)
      }

      acc = [beat | c.rq_acc]

      if beat.last,
        do: finish_rq(%{c | rq_acc: []}, Enum.reverse(acc)),
        else: %{c | rq_acc: acc}
    else
      c
    end
  end

  defp finish_rq(c, beats) do
    case Axis.rq_to_tlp(beats, c.cfg.requester_id) do
      {:ok, tlp, user} ->
        c |> check_rq(tlp, user) |> apply_rq(tlp) |> then(&%{&1 | rq_log: [tlp | &1.rq_log]})

      {:error, reason} ->
        err(c, {:bad_rq, reason})
    end
  end

  defp check_rq(c, tlp, user) do
    bytes = TLP.length_dw(tlp) * 4
    limit = if tlp.kind == :mwr, do: c.cfg.mps, else: c.cfg.mrrs

    be_ok =
      if bytes == 4,
        do: user.last_be == 0 and user.first_be != 0,
        else: user.first_be != 0 and user.last_be != 0

    c = if bytes > limit, do: err(c, {:rq_too_long, tlp.kind, bytes, limit}), else: c

    c =
      if (tlp.address &&& 0xFFF) + bytes > 4096,
        do: err(c, {:rq_crosses_4k, tlp.address, bytes}),
        else: c

    if be_ok, do: c, else: err(c, {:rq_bad_be, user.first_be, user.last_be})
  end

  defp apply_rq(c, %TLP{kind: :mwr} = t) do
    {c, _} = mem_write(c, t.address, t.data)
    %{c | stats: bump(c.stats, :rq_writes)}
  end

  defp apply_rq(c, %TLP{kind: :mrd} = t) do
    bytes = t.length_dw * 4
    c = %{c | stats: bump(c.stats, :rq_reads)}

    cond do
      Map.has_key?(c.outstanding, t.tag) ->
        err(c, {:tag_reused, t.tag})

      map_size(c.outstanding) >= c.cfg.max_tags ->
        err(c, {:too_many_outstanding, t.tag})

      true ->
        schedule_completions(
          %{c | outstanding: Map.put(c.outstanding, t.tag, t.address)},
          t,
          bytes
        )
    end
  end

  defp schedule_completions(c, t, bytes) do
    cfg = c.cfg
    {lo, hi} = cfg.latency
    {base, rng} = :rand.uniform_s(hi - lo + 1, c.rng)
    c = %{c | rng: rng}
    ready0 = c.cycle + lo + base - 1
    stop = t.address + bytes

    {items, c} =
      if t.address in cfg.error_reads do
        cpl = %TLP{
          kind: :cpl,
          status: TLP.status(:ur),
          completer_id: cfg.completer_id,
          requester_id: cfg.requester_id,
          tag: t.tag,
          byte_count: 4,
          length_dw: 0
        }

        {[{ready0, Axis.rc_beats(cpl, t.address, true, error_code: 2), true}], c}
      else
        {cuts, c} = pick_cuts(c, t.address, stop)
        chunks = TLP.completion_chunks(t.address, bytes, cfg.rcb, cfg.mps, cuts)
        n = length(chunks)

        {items, c} =
          chunks
          |> Enum.with_index()
          |> Enum.map_reduce(c, fn {{a, len}, i}, c ->
            {c, data} = mem_read(c, a, len)

            cpl = %TLP{
              kind: :cpld,
              completer_id: cfg.completer_id,
              requester_id: cfg.requester_id,
              tag: t.tag,
              byte_count: stop - a,
              lower_address: a &&& 0x7F,
              length_dw: div(len, 4),
              data: data
            }

            {{ready0 + i, Axis.rc_beats(cpl, a, i == n - 1), i == n - 1}, c}
          end)

        {items, c}
      end

    %{c | rc_reqs: c.rc_reqs ++ [{t.tag, items}]}
  end

  defp pick_cuts(c, start, stop) do
    case c.cfg.cuts do
      :random ->
        boundaries =
          Stream.iterate(div(start, c.cfg.rcb) * c.cfg.rcb + c.cfg.rcb, &(&1 + c.cfg.rcb))
          |> Enum.take_while(&(&1 < stop))

        {set, c} =
          Enum.reduce(boundaries, {MapSet.new(), c}, fn b, {set, c} ->
            {yes, c} = coin(c, 0.5)
            {if(yes, do: MapSet.put(set, b), else: set), c}
          end)

        {&MapSet.member?(set, &1), c}

      other ->
        {other, c}
    end
  end

  defp sample_irq(c, outs) do
    msix = g(outs, :cfg_msix_int) == 1 and c.cfg.msix_enable
    msi = g(outs, :cfg_msi_int) != 0 and c.cfg.msi_enable

    c =
      cond do
        (msix or msi) and c.irq_req != nil ->
          err(c, :irq_request_while_pending)

        msix ->
          start_irq(c, {:msix, g(outs, :cfg_msix_address), g(outs, :cfg_msix_data)})

        msi ->
          vec = g(outs, :cfg_msi_int) |> then(&(:math.log2(&1 &&& -&1) |> round()))
          start_irq(c, {:msi, vec})

        true ->
          c
      end

    tick_irq(c)
  end

  defp start_irq(c, what) do
    {lo, hi} = c.cfg.irq_latency
    {d, rng} = :rand.uniform_s(hi - lo + 1, c.rng)
    %{c | rng: rng, irq_req: {what, d + lo - 1}}
  end

  defp tick_irq(%{irq_req: nil} = c), do: c

  defp tick_irq(%{irq_req: {what, 0}} = c) do
    {fail?, c} = coin(c, c.cfg.irq_fail)
    kind = if elem(what, 0) == :msix, do: 1, else: 2

    if fail? do
      %{c | irq_req: nil, irq_fail: kind}
    else
      entry = {c.cycle, what}
      if c.cfg.on_irq, do: c.cfg.on_irq.(c, entry)

      %{
        c
        | irq_req: nil,
          irq_sent: kind,
          irq_log: [entry | c.irq_log],
          stats: bump(c.stats, :interrupts)
      }
    end
  end

  defp tick_irq(%{irq_req: {what, n}} = c), do: %{c | irq_req: {what, n - 1}}
end
