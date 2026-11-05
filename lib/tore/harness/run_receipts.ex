defmodule Tore.Harness.RunReceipts do
  @moduledoc """
  The user-facing view over the harness Run aggregate. A receipt is derived
  from an `Applied` (or `Reverted`) run by:

    * reading the run's typed artifacts and projecting them into
      cross-surface `DiffRow`s (UI_SPEC §16.4 alphabet);
    * exposing the stored `UndoPayload` so the UI can decide whether the
      Undo button is enabled.

  No separate persistence: the Run event stream is the source of truth.

  Phase 1 only ships the read facade and a `revert/1` that transitions the
  Run aggregate. The actual aggregate compensation (appending compensating
  events to the planning stream, restoring pantry snapshots) is Phase 3.
  """

  import Ecto.Query

  alias Tore.EventStore.Event
  alias Tore.Harness.{DiffRow, Run, UndoPayload}
  alias Tore.Harness.Run.{Commands, State}
  alias Tore.Harness.Artifact.{CostEntry, MemoryUpdate, PantryBeliefUpdate, PlanDiff, RunSummary}
  alias Tore.Repo

  @type receipt :: %{
          stream_id: String.t(),
          household_id: term(),
          user_id: term(),
          trigger: atom(),
          intent: String.t() | nil,
          diff_rows: [DiffRow.t()],
          undo_payload: UndoPayload.t() | nil,
          applied_at: DateTime.t() | nil,
          reverted_at: DateTime.t() | nil
        }

  @spec get(String.t()) :: {:ok, receipt()} | {:error, :not_applied | :not_found}
  def get(stream_id) do
    case Run.load(stream_id) do
      {:ok, %State.Draft{}} -> {:error, :not_found}
      {:ok, %State.Applied{} = s} -> {:ok, to_receipt(s)}
      {:ok, %State.Reverted{} = s} -> {:ok, to_receipt(s)}
      {:ok, _other} -> {:error, :not_applied}
    end
  end

  @spec list_for_household(term()) :: [receipt()]
  def list_for_household(household_id) do
    from(e in Event,
      where: e.stream_type == "run" and e.event_type == "Opened",
      where: fragment("json_extract(?, '$.household_id') = ?", e.data, ^household_id),
      select: e.stream_id,
      order_by: [desc: e.id]
    )
    |> Repo.all()
    |> Enum.flat_map(fn sid ->
      case get(sid) do
        {:ok, r} -> [r]
        _ -> []
      end
    end)
  end

  @spec to_diff_rows([struct()]) :: [DiffRow.t()]
  def to_diff_rows(artifacts) when is_list(artifacts),
    do: Enum.flat_map(artifacts, &rows_for/1)

  @spec revert(String.t()) :: :ok | {:error, term()}
  def revert(stream_id) do
    with {:ok, applied} <- load_applied(stream_id) do
      revert_applied(applied)
    end
  end

  @doc """
  Atomically compensate an Applied run and append the Reverted event in
  one DB transaction. If any compensator returns `{:error, _}`, the whole
  transaction rolls back: planning event stream stays as it was, pantry
  rows stay as they were, the Run remains `Applied`. The user sees an
  error and can retry.

  Exposed for tests that need to drive a doctored `%State.Applied{}`
  through the revert path without round-tripping through `Run.load/1`.
  """
  @spec revert_applied(State.Applied.t()) :: :ok | {:error, term()}
  def revert_applied(%State.Applied{undo_payload: payload} = applied) do
    with :ok <- reversible?(payload) do
      Repo.transaction(fn ->
        with :ok <- compensate(payload),
             {:ok, events} <- Run.decide(%Commands.Revert{}, applied),
             :ok <- Run.append(applied.stream_id, events, %{household_id: applied.household_id}) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end


  # ----- receipt projection ---------------------------------------------------

  defp to_receipt(%State.Applied{} = s) do
    %{
      stream_id: s.stream_id,
      household_id: s.household_id,
      user_id: s.user_id,
      trigger: s.started_by,
      intent: intent_from_input(s.input),
      diff_rows: to_diff_rows(s.artifacts),
      undo_payload: s.undo_payload,
      applied_at: s.committed_at,
      reverted_at: nil
    }
  end

  defp to_receipt(%State.Reverted{} = s) do
    %{
      stream_id: s.stream_id,
      household_id: s.household_id,
      user_id: s.user_id,
      trigger: s.started_by,
      intent: intent_from_input(s.input),
      diff_rows: to_diff_rows(s.artifacts),
      undo_payload: nil,
      applied_at: nil,
      reverted_at: s.reverted_at
    }
  end

  defp intent_from_input(input) when is_map(input),
    do: input[:command] || input["command"]

  defp intent_from_input(_), do: nil

  # ----- per-artifact row projection ------------------------------------------

  defp rows_for(%PlanDiff{events: events}),
    do: Enum.map(events, &plan_event_to_row/1)

  defp rows_for(%PantryBeliefUpdate{items: items}),
    do: Enum.map(items, &pantry_item_to_row/1)

  defp rows_for(%CostEntry{} = entry) do
    [
      %DiffRow{
        op: :added,
        surface: :cost,
        label: "Receipt from #{entry.store_name}",
        reason: nil
      }
    ]
  end

  defp rows_for(%MemoryUpdate{}), do: []
  defp rows_for(%RunSummary{}), do: []
  defp rows_for(_other), do: []

  defp plan_event_to_row(%{event_type: type, slot_key: slot, payload: payload, rationale: rat}) do
    {op, verb} = plan_op(type)
    label = payload["label"] || payload[:label] || slot

    %DiffRow{
      op: op,
      surface: :plan,
      label: "#{verb} #{label}",
      reason: List.first(rat || [])
    }
  end

  defp plan_op("RecipeAssigned"), do: {:added, "Added"}
  defp plan_op("RecipeSwapped"), do: {:changed, "Swapped to"}
  defp plan_op("RecipeRemoved"), do: {:removed, "Removed"}
  defp plan_op("MealSkipped"), do: {:removed, "Skipped"}
  defp plan_op("LeftoverMarked"), do: {:added, "Leftover for"}
  defp plan_op("ServingsChanged"), do: {:changed, "Servings for"}
  defp plan_op(_), do: {:changed, "Updated"}

  defp pantry_item_to_row(%{change: change, name: name, provenance: prov}) do
    {op, verb} =
      case change do
        :added -> {:added, "Added"}
        :bumped -> {:changed, "Refreshed"}
        :removed -> {:removed, "Removed"}
      end

    %DiffRow{
      op: op,
      surface: :pantry,
      label: "#{verb} #{name}",
      reason: "via #{prov}"
    }
  end

  # ----- revert plumbing ------------------------------------------------------

  defp load_applied(stream_id) do
    case Run.load(stream_id) do
      {:ok, %State.Draft{}} -> {:error, :not_found}
      {:ok, %State.Applied{} = s} -> {:ok, s}
      {:ok, _other} -> {:error, :not_applied}
    end
  end

  defp reversible?(%UndoPayload{kind: :irreversible}), do: {:error, :irreversible}
  defp reversible?(_), do: :ok

  defp compensate(%UndoPayload{kind: :composite, data: %{children: children}}) do
    # Children compensate in reverse order so the most recent effect rolls
    # back first, matching how the user perceives an "undo".
    Enum.reduce_while(Enum.reverse(children), :ok, fn child, :ok ->
      case compensate(child) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp compensate(%UndoPayload{kind: :event_sourced, data: %{stream_type: "planning"} = data}) do
    events = Enum.map(data.compensating_events, &to_planning_event/1)
    Tore.Planning.apply_events(data.stream_id, events)
  end

  defp compensate(%UndoPayload{kind: :snapshot, data: %{schema: "Tore.Pantry.PantryItem"} = data}) do
    # Newest first: two changes to one row must end on the earliest "before".
    Enum.reduce_while(Enum.reverse(data.changes), :ok, fn change, :ok ->
      case restore_pantry_change(change) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp compensate(_payload), do: :ok

  defp to_planning_event(%{event_type: "RecipeRemoved", slot_key: sk}),
    do: %Tore.Planning.Events.RecipeRemoved{slot_key: sk}

  defp restore_pantry_change(%{item_id: id, before: nil}) do
    case Tore.Pantry.remove_item(id) do
      :ok -> :ok
      # The row may already be gone (compensation should be idempotent).
      {:error, :not_found} -> :ok
    end
  end

  defp restore_pantry_change(%{item_id: id, before: before}) do
    case Tore.Repo.get(Tore.Pantry.PantryItem, id) do
      nil ->
        :ok

      item ->
        item
        |> Tore.Pantry.PantryItem.changeset(restore_attrs(before))
        |> Tore.Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  # Legacy snapshot shape derived directly from PantryBeliefUpdate before
  # PantrySnapshot existed. We cannot compensate without row identity.
  defp restore_pantry_change(_legacy), do: :ok

  defp restore_attrs(before) do
    before
    |> Map.take([:last_seen_at, :provenance, :belief, :added_at])
    |> Map.reject(fn {_, v} -> is_nil(v) end)
    |> Map.merge(%{
      quantity: before[:quantity],
      unit: before[:unit],
      expires_at: before[:expires_at],
      expires_source: before[:expires_source]
    })
  end
end
