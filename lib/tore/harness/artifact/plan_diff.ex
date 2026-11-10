defmodule Tore.Harness.Artifact.PlanDiff do
  @behaviour Tore.Harness.Artifact

  @type event_entry :: %{
          slot_key: String.t(),
          event_type: String.t(),
          payload: map(),
          rationale: [String.t()]
        }

  @type rollup_change :: :added | :swapped | :skipped | :leftover | :removed | :servings

  @type rollup_entry :: %{
          slot_key: String.t(),
          change: rollup_change(),
          label: String.t() | nil,
          rationale: [String.t()]
        }

  # `events` describe the change for the receipt; `plan_events` are what applying it appends.
  @derive {Jason.Encoder, only: [:plan_stream_id, :week_start, :events]}
  @enforce_keys [:plan_stream_id, :week_start, :events]
  defstruct [:plan_stream_id, :week_start, :events, plan_events: []]

  @type t :: %__MODULE__{
          plan_stream_id: String.t(),
          week_start: Date.t(),
          events: [event_entry()],
          plan_events: [Tore.Planning.Events.t()]
        }

  @impl true
  def kind, do: "PlanDiff"

  @spec summarise(t()) :: [rollup_entry()]
  def summarise(%__MODULE__{events: events}) do
    events
    |> Enum.group_by(& &1.slot_key)
    |> Enum.map(fn {slot_key, slot_events} -> rollup_for(slot_key, slot_events) end)
  end

  @impl true
  def summary(%__MODULE__{} = diff) do
    rollup = summarise(diff)
    counts = Enum.frequencies_by(rollup, & &1.change)
    %{counts: counts, text_fallback: text_from_counts(counts)}
  end

  @impl true
  def is_rationale_complete(%__MODULE__{events: events}),
    do: Enum.all?(events, fn e -> e.rationale != [] end)

  @impl true
  def to_json(%__MODULE__{plan_stream_id: psid, week_start: ws, events: events} = diff) do
    %{
      "plan_stream_id" => psid,
      "week_start" => Date.to_iso8601(ws),
      "events" => Enum.map(events, &event_to_json/1),
      "plan_events" => Enum.map(diff.plan_events, &Tore.Planning.Events.to_json/1)
    }
  end

  @impl true
  def from_json(%{
        "plan_stream_id" => psid,
        "week_start" => ws,
        "events" => events,
        "plan_events" => plan_events
      }) do
    %__MODULE__{
      plan_stream_id: psid,
      week_start: Date.from_iso8601!(ws),
      events: Enum.map(events, &event_from_json/1),
      plan_events: Enum.map(plan_events, &Tore.Planning.Events.from_json/1)
    }
  end

  defp event_to_json(%{slot_key: sk, event_type: et, payload: p, rationale: r}),
    do: %{"slot_key" => sk, "event_type" => et, "payload" => p, "rationale" => r}

  defp event_from_json(%{"slot_key" => sk, "event_type" => et, "payload" => p, "rationale" => r}),
    do: %{slot_key: sk, event_type: et, payload: p, rationale: r}

  defp rollup_for(slot_key, slot_events) do
    types = Enum.map(slot_events, & &1.event_type)
    rationale = slot_events |> Enum.flat_map(& &1.rationale)
    label = slot_events |> Enum.reverse() |> Enum.find_value(fn e -> e.payload["label"] end)

    change =
      cond do
        "RecipeSwapped" in types -> :swapped
        "RecipeAssigned" in types -> :added
        "MealSkipped" in types -> :skipped
        "LeftoverMarked" in types -> :leftover
        "RecipeRemoved" in types -> :removed
        "ServingsChanged" in types -> :servings
        true -> :added
      end

    %{slot_key: slot_key, change: change, label: label, rationale: rationale}
  end

  defp text_from_counts(counts) do
    counts
    |> Enum.map(fn {change, n} -> "#{n} #{change_label(change)}" end)
    |> Enum.join(", ")
  end

  defp change_label(:added), do: "added"
  defp change_label(:swapped), do: "swapped"
  defp change_label(:skipped), do: "skipped"
  defp change_label(:leftover), do: "leftovers"
  defp change_label(:removed), do: "removed"
  defp change_label(:servings), do: "servings adjusted"
  defp change_label(other), do: to_string(other)
end
