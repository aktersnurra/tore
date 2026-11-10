defmodule Tore.Harness.Run do
  import Ecto.Query
  alias Tore.Harness.Run.{Decider, Events, State}
  alias Tore.Harness.{Artifact, UndoPayload}
  alias Tore.EventStore
  alias Tore.EventStore.Event
  alias Tore.{Repo, Scope}

  @stream_type "run"

  @spec next_stream_id() :: String.t()
  def next_stream_id,
    do: "run-" <> (:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false))

  @doc "A run as its household sees it. Another household's run loads as an empty `Draft`."
  @spec load(Scope.t(), String.t()) :: {:ok, State.t()}
  def load(%Scope{} = scope, stream_id) do
    state =
      from(e in Event,
        where: e.stream_id == ^stream_id and e.stream_type == ^@stream_type,
        order_by: [asc: e.id]
      )
      |> Repo.all(Scope.repo_opts(scope))
      |> Enum.reduce(%State.Draft{stream_id: stream_id}, fn raw, acc ->
        event = deserialize(raw.event_type, raw.data)
        Decider.evolve(acc, event)
      end)

    {:ok, state}
  end

  defdelegate decide(command, state), to: Decider
  defdelegate evolve(state, event), to: Decider

  @spec append(Scope.t(), String.t(), [struct()]) :: :ok | {:error, term()}
  def append(%Scope{household_id: hh} = scope, stream_id, events) do
    EventStore.append(scope, stream_id, Enum.map(events, &prepare/1),
      broadcast: "harness:household:#{hh}",
      broadcast_tag: :run_event
    )
  end

  defp prepare(%Events.ArtifactAdded{artifact: %_{} = artifact} = ev),
    do: %Events.ArtifactAdded{ev | artifact: Artifact.to_json(artifact)}

  defp prepare(%Events.FailureRecorded{repair_action: {:edit_plan, slots}} = ev),
    do: %Events.FailureRecorded{ev | repair_action: %{"action" => "edit_plan", "slots" => slots}}

  defp prepare(%Events.Committed{undo_payload: %UndoPayload{} = p} = ev),
    do: %Events.Committed{ev | undo_payload: UndoPayload.to_json(p)}

  defp prepare(event), do: event

  defp deserialize(event_type, data) do
    module = Module.concat([Tore.Harness.Run.Events, event_type])
    attrs = Jason.decode!(data, keys: :atoms)
    rehydrate(struct!(module, attrs))
  end

  defp rehydrate(%Events.ArtifactAdded{artifact: payload}) when is_map(payload) do
    %Events.ArtifactAdded{artifact: rehydrate_artifact(payload)}
  end

  defp rehydrate(%Events.ModelUsageObserved{cost_usd: cost} = event),
    do: %Events.ModelUsageObserved{event | cost_usd: to_decimal(cost)}

  defp rehydrate(%Events.PhaseEntered{phase: phase} = event) when is_binary(phase),
    do: %Events.PhaseEntered{event | phase: phase_atom(phase)}

  defp rehydrate(%Events.Opened{} = event) do
    %Events.Opened{
      event
      | surface: surface_to_atom(event.surface),
        opened_at: parse_datetime(event.opened_at)
    }
  end

  defp rehydrate(%Events.PhaseEntered{at: at} = event),
    do: %Events.PhaseEntered{event | at: parse_datetime(at)}

  defp rehydrate(%Events.QuestionRaised{at: at} = event),
    do: %Events.QuestionRaised{event | at: parse_datetime(at)}

  defp rehydrate(%Events.QuestionAnswered{at: at} = event),
    do: %Events.QuestionAnswered{event | at: parse_datetime(at)}

  defp rehydrate(%Events.Committed{at: at, undo_payload: payload} = event),
    do: %Events.Committed{
      event
      | at: parse_datetime(at),
        undo_payload: rehydrate_undo_payload(payload)
    }

  defp rehydrate(%Events.Reverted{at: at} = event),
    do: %Events.Reverted{event | at: parse_datetime(at)}

  defp rehydrate(%Events.FailureRecorded{at: at} = event),
    do: %Events.FailureRecorded{
      event
      | code: failure_code_atom(event.code),
        repair_action: decode_repair(event.repair_action),
        at: parse_datetime(at)
    }

  defp rehydrate(%Events.ToolStepRecorded{step_kind: sk} = event) when is_binary(sk),
    do: %Events.ToolStepRecorded{event | step_kind: step_kind_atom(sk)}

  defp rehydrate(%Events.RunDiscarded{reason: r, at: at} = event) when is_binary(r),
    do: %Events.RunDiscarded{event | reason: discard_reason_atom(r), at: parse_datetime(at)}

  defp rehydrate(event), do: event

  defp surface_to_atom(s) when is_atom(s), do: s
  defp surface_to_atom(s) when is_binary(s), do: surface_atom(s)

  defp discard_reason_atom("user_discarded"), do: :user_discarded
  defp discard_reason_atom("ttl_expired"), do: :ttl_expired

  # Closed enums coerced via explicit maps so rehydration never depends on the
  # defining module being loaded — the Projector replays open runs at boot,
  # before PlannerAgent (which defines :tool_calls/:tool_result/:message) loads,
  # so String.to_existing_atom/1 would raise :badarg on a cold start.
  defp step_kind_atom("tool_calls"), do: :tool_calls
  defp step_kind_atom("tool_result"), do: :tool_result
  defp step_kind_atom("message"), do: :message

  defp phase_atom("gathering_context"), do: :gathering_context
  defp phase_atom("proposing"), do: :proposing
  defp phase_atom("verifying"), do: :verifying

  defp surface_atom("plan"), do: :plan

  # Failure codes are matched in the receipt as atoms; decode via a literal map so
  # a cold Projector boot (PlanVerifier not yet loaded) never downgrades them to a
  # string the way String.to_existing_atom would. Unknown strings fall back to
  # safe_atom (tolerant). Atoms (warm path) pass through.
  defp failure_code_atom("internal_error"), do: :internal_error
  defp failure_code_atom("slot_pinned"), do: :slot_pinned
  defp failure_code_atom("servings_missing"), do: :servings_missing
  defp failure_code_atom("skip_not_explicit"), do: :skip_not_explicit
  defp failure_code_atom("leftover_no_source"), do: :leftover_no_source
  defp failure_code_atom("dietary_violation"), do: :dietary_violation
  defp failure_code_atom("invalid_insight_kind"), do: :invalid_insight_kind
  defp failure_code_atom("invalid_confidence"), do: :invalid_confidence
  defp failure_code_atom("missing_body"), do: :missing_body
  defp failure_code_atom("missing_evidence"), do: :missing_evidence
  defp failure_code_atom("too_many_active"), do: :too_many_active
  defp failure_code_atom("missing_store"), do: :missing_store
  defp failure_code_atom("missing_date"), do: :missing_date
  defp failure_code_atom("missing_total"), do: :missing_total
  defp failure_code_atom("date_in_future"), do: :date_in_future
  defp failure_code_atom("sum_mismatch"), do: :sum_mismatch
  defp failure_code_atom("missing_provenance"), do: :missing_provenance
  defp failure_code_atom("negative_quantity"), do: :negative_quantity
  defp failure_code_atom("last_seen_regressed"), do: :last_seen_regressed
  defp failure_code_atom(code) when is_atom(code), do: code
  defp failure_code_atom(other), do: safe_atom(other)

  # repair_action round-trips as a map (planner) or a string (memory: "reject").
  # Reconstruct via a literal map (cold-boot safe — no String.to_existing_atom).
  defp decode_repair(%{action: "edit_plan", slots: slots}), do: {:edit_plan, slots}
  defp decode_repair(%{"action" => "edit_plan", "slots" => slots}), do: {:edit_plan, slots}
  defp decode_repair("reject"), do: :reject
  defp decode_repair(:reject), do: :reject
  defp decode_repair(nil), do: nil
  defp decode_repair(other), do: other

  # failure code/repair_action are more open-ended; tolerate any string without
  # crashing, and pass non-binaries (e.g. nil) through unchanged.
  defp safe_atom(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> s
  end

  defp safe_atom(v), do: v

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  # Events store timestamps as ISO-8601 strings via Jason. On the warm
  # write path they're %DateTime{}; on cold reload they're strings.
  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp rehydrate_artifact(payload) do
    kind = Map.get(payload, :__kind__) || Map.get(payload, "__kind__")
    {:ok, module} = Artifact.Registry.lookup(kind)
    module.from_json(stringify_keys(payload))
  end

  defp rehydrate_undo_payload(nil), do: nil
  defp rehydrate_undo_payload(%UndoPayload{} = p), do: p

  defp rehydrate_undo_payload(payload) when is_map(payload),
    do: payload |> stringify_keys() |> UndoPayload.from_json()

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(v), do: v
end
