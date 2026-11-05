defmodule Tore.Harness.UndoPayload do
  @moduledoc """
  How a committed Run is reversed. Stored on `Events.Committed` so a
  rehydrated `State.Applied` carries everything Phase 3's compensators need
  without having to re-read external aggregates.

  Sum type encoded as `{kind, data}`:

    * `:event_sourced` — `%{stream_id, stream_type, event_types}`. Phase 3's
      compensator appends compensating events to the named stream.
    * `:snapshot` — `%{schema, changes}`. Phase 3's compensator restores the
      before-state on each affected row.
    * `:composite` — `%{children: [UndoPayload]}`. Compensators run in
      reverse order.
    * `:irreversible` — `%{reason}`. The Undo button is disabled; the row
      shows the reason.

  `from_artifacts/1` derives the payload from a run's typed artifacts at
  commit time. Each artifact kind has a hard-coded reversal strategy; an
  artifact this module doesn't recognise is treated as irreversible (the
  conservative default — Phase 3 can extend the dispatcher).
  """

  alias Tore.Harness.Artifact.{
    CostEntry,
    MemoryUpdate,
    PantryBeliefUpdate,
    PantrySnapshot,
    PlanDiff,
    RunSummary
  }

  @kinds [:event_sourced, :snapshot, :composite, :irreversible]

  @derive Jason.Encoder
  @enforce_keys [:kind, :data]
  defstruct [:kind, :data]

  @type kind :: :event_sourced | :snapshot | :composite | :irreversible
  @type t :: %__MODULE__{kind: kind(), data: map()}

  def kinds, do: @kinds

  @doc """
  Compose a list of already-built child payloads (e.g. from each child Run
  of a turn-Run) into a single payload. Mirrors `from_artifacts/1`'s
  composition rules but works on payloads, not artifacts — needed when the
  children live in separate Run streams.
  """
  @spec compose([t() | nil]) :: t()
  def compose(payloads) when is_list(payloads) do
    case Enum.reject(payloads, &is_nil/1) do
      [] ->
        irreversible("no child payloads")

      [single] ->
        single

      multiple ->
        if Enum.any?(multiple, &(&1.kind == :irreversible)) do
          irreversible("bundle contains an irreversible child")
        else
          %__MODULE__{kind: :composite, data: %{children: multiple}}
        end
    end
  end

  @spec from_artifacts([struct()]) :: t()
  def from_artifacts([]),
    do: irreversible("run produced no reversible artifacts")

  def from_artifacts(artifacts) when is_list(artifacts) do
    # A `PantrySnapshot` carries the row-level before-state captured at
    # mutation time; when present it supersedes the coarser `:snapshot`
    # payload that would otherwise be derived from `PantryBeliefUpdate`.
    artifacts =
      if Enum.any?(artifacts, &match?(%PantrySnapshot{}, &1)) do
        Enum.reject(artifacts, &match?(%PantryBeliefUpdate{}, &1))
      else
        artifacts
      end

    case artifacts |> Enum.map(&payload_for/1) |> Enum.reject(&is_nil/1) do
      [] ->
        irreversible("run produced no reversible artifacts")

      [single] ->
        single

      multiple ->
        if Enum.any?(multiple, &(&1.kind == :irreversible)) do
          irreversible("composite run contains an irreversible artifact")
        else
          %__MODULE__{kind: :composite, data: %{children: multiple}}
        end
    end
  end

  # ----- per-artifact strategy ------------------------------------------------

  defp payload_for(%PlanDiff{plan_stream_id: sid, events: events}) do
    compensating = Enum.map(events, &invert_plan_event/1)

    if compensating == [] or Enum.any?(compensating, &is_nil/1) do
      irreversible("plan diff contains an event with no known inverse")
    else
      %__MODULE__{
        kind: :event_sourced,
        data: %{
          stream_id: sid,
          stream_type: "planning",
          event_types: Enum.map(events, & &1.event_type),
          compensating_events: Enum.reverse(compensating)
        }
      }
    end
  end

  defp payload_for(%PantrySnapshot{items: items}) do
    %__MODULE__{
      kind: :snapshot,
      data: %{
        schema: "Tore.Pantry.PantryItem",
        changes:
          Enum.map(items, fn it ->
            %{item_id: it.item_id, before: it.before}
          end)
      }
    }
  end

  defp payload_for(%PantryBeliefUpdate{items: items}) do
    %__MODULE__{
      kind: :snapshot,
      data: %{
        schema: "Tore.Pantry.PantryItem",
        changes: Enum.map(items, &snapshot_change/1)
      }
    }
  end

  defp payload_for(%CostEntry{}),
    do: irreversible("cost ledger entries are not reversible from the receipt")

  defp payload_for(%MemoryUpdate{}),
    do: irreversible("memory updates are not reversible from the receipt")

  # RunSummary describes what happened; it has no state to reverse.
  defp payload_for(%RunSummary{}), do: nil

  defp payload_for(_other),
    do: irreversible("unknown artifact kind")

  # The inverse of each plan event we know how to compensate. New events the
  # Planning aggregate gains over time must be added here or the run will be
  # marked irreversible at commit time.
  defp invert_plan_event(%{event_type: "RecipeAssigned", slot_key: sk}),
    do: %{event_type: "RecipeRemoved", slot_key: sk, payload: %{}}

  defp invert_plan_event(_other), do: nil

  defp snapshot_change(item) do
    %{
      change: item.change,
      name: item.name,
      quantity: item[:quantity],
      unit: item[:unit],
      provenance: item.provenance
    }
  end

  defp irreversible(reason),
    do: %__MODULE__{kind: :irreversible, data: %{reason: reason}}

  # ----- JSON round-trip ------------------------------------------------------

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{kind: :composite, data: %{children: children}}) do
    %{"kind" => "composite", "data" => %{"children" => Enum.map(children, &to_json/1)}}
  end

  def to_json(%__MODULE__{kind: :snapshot, data: data}) do
    changes = Enum.map(data.changes, &snapshot_change_to_json/1)
    %{"kind" => "snapshot", "data" => %{"schema" => data.schema, "changes" => changes}}
  end

  def to_json(%__MODULE__{kind: :event_sourced, data: data}) do
    %{
      "kind" => "event_sourced",
      "data" => %{
        "stream_id" => data.stream_id,
        "stream_type" => data.stream_type,
        "event_types" => data.event_types,
        "compensating_events" => Enum.map(data.compensating_events, &comp_event_to_json/1)
      }
    }
  end

  def to_json(%__MODULE__{kind: kind, data: data}) when kind in @kinds do
    %{"kind" => Atom.to_string(kind), "data" => map_keys_to_strings(data)}
  end

  @spec from_json(map()) :: t()
  def from_json(%{"kind" => "composite", "data" => %{"children" => children}}) do
    %__MODULE__{
      kind: :composite,
      data: %{children: Enum.map(children, &from_json/1)}
    }
  end

  def from_json(%{"kind" => "snapshot", "data" => %{"schema" => schema, "changes" => changes}}) do
    %__MODULE__{
      kind: :snapshot,
      data: %{schema: schema, changes: Enum.map(changes, &snapshot_change_from_json/1)}
    }
  end

  def from_json(%{"kind" => "event_sourced", "data" => data}) do
    %__MODULE__{
      kind: :event_sourced,
      data: %{
        stream_id: data["stream_id"],
        stream_type: data["stream_type"],
        event_types: data["event_types"] || [],
        compensating_events:
          Enum.map(data["compensating_events"] || [], &comp_event_from_json/1)
      }
    }
  end

  def from_json(%{"kind" => kind_str, "data" => data}) do
    kind = String.to_existing_atom(kind_str)
    true = kind in @kinds
    %__MODULE__{kind: kind, data: map_keys_to_atoms(data)}
  end

  defp comp_event_to_json(%{event_type: et, slot_key: sk, payload: p}),
    do: %{"event_type" => et, "slot_key" => sk, "payload" => p}

  defp comp_event_from_json(%{"event_type" => et, "slot_key" => sk} = m),
    do: %{event_type: et, slot_key: sk, payload: m["payload"] || %{}}

  defp snapshot_change_to_json(%{item_id: id, before: before}) do
    %{"item_id" => id, "before" => before_to_json(before)}
  end

  defp snapshot_change_to_json(change) do
    # Legacy shape derived directly from PantryBeliefUpdate (kept for
    # back-compat with old events that pre-date PantrySnapshot).
    %{
      "change" => Atom.to_string(change.change),
      "name" => Map.get(change, :name),
      "quantity" => decimal_to_string(Map.get(change, :quantity)),
      "unit" => Map.get(change, :unit),
      "provenance" => Map.get(change, :provenance)
    }
  end

  defp snapshot_change_from_json(%{"item_id" => id} = m) do
    %{item_id: id, before: before_from_json(m["before"])}
  end

  defp snapshot_change_from_json(m) do
    %{
      change: String.to_existing_atom(m["change"]),
      name: m["name"],
      quantity: m["quantity"],
      unit: m["unit"],
      provenance: m["provenance"]
    }
  end

  defp date_to_iso(%Date{} = date), do: Date.to_iso8601(date)
  defp date_to_iso(other), do: other

  defp before_to_json(nil), do: nil

  defp before_to_json(b) when is_map(b) do
    %{
      "quantity" => decimal_to_string(b[:quantity]),
      "unit" => b[:unit],
      "last_seen_at" => datetime_to_iso(b[:last_seen_at]),
      "provenance" => b[:provenance],
      "belief" => b[:belief],
      "added_at" => date_to_iso(b[:added_at]),
      "expires_at" => date_to_iso(b[:expires_at]),
      "expires_source" => b[:expires_source]
    }
  end

  defp before_from_json(nil), do: nil

  defp before_from_json(b) when is_map(b) do
    %{
      quantity: b["quantity"],
      unit: b["unit"],
      last_seen_at: iso_to_datetime(b["last_seen_at"]),
      provenance: b["provenance"],
      belief: b["belief"],
      added_at: b["added_at"],
      expires_at: b["expires_at"],
      expires_source: b["expires_source"]
    }
  end

  defp datetime_to_iso(nil), do: nil
  defp datetime_to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso(other), do: other

  defp iso_to_datetime(nil), do: nil

  defp iso_to_datetime(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp iso_to_datetime(other), do: other

  defp map_keys_to_strings(data) when is_map(data),
    do: for({k, v} <- data, into: %{}, do: {to_string(k), v})

  defp map_keys_to_atoms(data) when is_map(data),
    do: for({k, v} <- data, into: %{}, do: {String.to_existing_atom(k), v})

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_string(other), do: other
end
