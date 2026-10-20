defmodule ExPcie.Model.Stream do
  @moduledoc """
  Plain AXI4-Stream agents for the user side of a design: `Source` feeds
  beats into a slave port, `Sink` collects beats from a master port, both
  with random `tvalid` gaps and `tready` stalls (`valid:` / `ready:`
  probabilities, seeded).

  A source beat is a map of field name to value (`%{tdata: v, tlast: 1}`);
  ports are `<prefix>_<field>`. Once `tvalid` is raised it holds until the
  beat is accepted.
  """

  defmodule Source do
    @behaviour ExPcie.Model.Agent
    defstruct [:prefix, :rng, beats: [], valid: 1.0, hold: false, sent: 0]

    def new(prefix, beats, opts \\ []) do
      %__MODULE__{
        prefix: prefix,
        beats: beats,
        valid: Keyword.get(opts, :valid, 1.0),
        rng: :rand.seed_s(:exsss, {Keyword.get(opts, :seed, 1), 11, 12})
      }
    end

    @doc "Appends beats."
    def push(s, beats), do: %{s | beats: s.beats ++ beats}
    def pending(s), do: length(s.beats)

    @impl true
    def drive(%{beats: []} = s, _), do: {%{:"#{s.prefix}_tvalid" => 0}, %{s | hold: false}}

    def drive(s, _) do
      {r, rng} = :rand.uniform_s(s.rng)
      v = s.hold or r < s.valid
      [b | _] = s.beats
      ins = for {k, x} <- b, into: %{}, do: {:"#{s.prefix}_#{k}", x}
      {Map.put(ins, :"#{s.prefix}_tvalid", if(v, do: 1, else: 0)), %{s | rng: rng, hold: v}}
    end

    @impl true
    def sample(s, outs, _) do
      if s.hold and Map.get(outs, :"#{s.prefix}_tready", 0) == 1,
        do: %{s | beats: tl(s.beats), hold: false, sent: s.sent + 1},
        else: s
    end
  end

  defmodule Sink do
    @behaviour ExPcie.Model.Agent
    defstruct [:prefix, :rng, ready: 1.0, ready_now: false, beats: []]

    def new(prefix, opts \\ []) do
      %__MODULE__{
        prefix: prefix,
        ready: Keyword.get(opts, :ready, 1.0),
        rng: :rand.seed_s(:exsss, {Keyword.get(opts, :seed, 1), 21, 22})
      }
    end

    @doc "Collected beats, oldest first."
    def beats(s), do: Enum.reverse(s.beats)

    @doc "Collected `tdata` values, oldest first."
    def data(s), do: s |> beats() |> Enum.map(& &1.tdata)

    @impl true
    def drive(s, _) do
      {r, rng} = :rand.uniform_s(s.rng)
      rdy = r < s.ready
      {%{:"#{s.prefix}_tready" => if(rdy, do: 1, else: 0)}, %{s | rng: rng, ready_now: rdy}}
    end

    @impl true
    def sample(s, outs, _) do
      if s.ready_now and Map.get(outs, :"#{s.prefix}_tvalid", 0) == 1 do
        pre = "#{s.prefix}_"

        beat =
          for {k, v} <- outs,
              String.starts_with?(Atom.to_string(k), pre),
              f = String.replace_prefix(Atom.to_string(k), pre, ""),
              f not in ["tvalid", "tready"],
              into: %{},
              do: {String.to_atom(f), v}

        %{s | beats: [beat | s.beats]}
      else
        s
      end
    end
  end
end
