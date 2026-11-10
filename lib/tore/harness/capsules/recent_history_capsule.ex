defmodule Tore.Harness.Capsules.RecentHistoryCapsule do
  @moduledoc """
  Last 6 weeks of planning behaviour: meals served, slots skipped, leftover
  cascades, swap rate, fill rate. Source is the planning event stream.

  The capsule answers "how does this household actually plan?" for the
  synthesis run and any agent that wants to reason about behavioural drift.
  """

  @behaviour Tore.Harness.Capsule

  import Ecto.Query
  alias Tore.{EventStore, Repo}

  @window_days 42
  @max_examples 6

  defstruct [
    :assigned,
    :skipped,
    :leftovers,
    :removed,
    :swap_rate,
    :skip_by_day,
    :recent_examples
  ]

  @type t :: %__MODULE__{
          assigned: non_neg_integer(),
          skipped: non_neg_integer(),
          leftovers: non_neg_integer(),
          removed: non_neg_integer(),
          swap_rate: float(),
          skip_by_day: %{String.t() => non_neg_integer()},
          recent_examples: [String.t()]
        }

  @impl true
  def build(ctx) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@window_days * 86_400, :second)
      |> DateTime.to_naive()

    events =
      from(e in EventStore.Event,
        where: e.stream_type == "planning" and e.inserted_at >= ^cutoff,
        order_by: [asc: e.id]
      )
      |> Repo.all(Tore.Scope.repo_opts(Tore.Scope.for_household(ctx.household_id)))

    counts = Enum.frequencies_by(events, & &1.event_type)
    assigned = Map.get(counts, "RecipeAssigned", 0)
    removed = Map.get(counts, "RecipeRemoved", 0)

    %__MODULE__{
      assigned: assigned,
      skipped: Map.get(counts, "MealSkipped", 0),
      leftovers: Map.get(counts, "LeftoverMarked", 0),
      removed: removed,
      swap_rate: swap_rate(assigned, removed),
      skip_by_day: skip_by_day(events),
      recent_examples: recent_examples(events)
    }
  end

  @impl true
  def to_prompt(%__MODULE__{assigned: 0, skipped: 0, leftovers: 0, removed: 0}), do: nil

  def to_prompt(%__MODULE__{} = c) do
    skip_line =
      case top_skip_days(c.skip_by_day) do
        [] -> nil
        days -> "Skip-heavy days: " <> Enum.join(days, ", ")
      end

    examples =
      case c.recent_examples do
        [] -> nil
        list -> "Recent activity:\n" <> Enum.map_join(list, "\n", &("  - " <> &1))
      end

    [
      "Last #{@window_days} days: #{c.assigned} meals planned, #{c.skipped} skipped, " <>
        "#{c.leftovers} leftover days, #{c.removed} removed " <>
        "(swap rate #{format_pct(c.swap_rate)}).",
      skip_line,
      examples
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp swap_rate(0, _), do: 0.0
  defp swap_rate(assigned, removed), do: Float.round(removed / assigned, 2)

  defp skip_by_day(events) do
    events
    |> Enum.filter(&(&1.event_type == "MealSkipped"))
    |> Enum.map(&day_from_event/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp top_skip_days(map) when map_size(map) == 0, do: []

  defp top_skip_days(map) do
    map
    |> Enum.sort_by(fn {_d, n} -> -n end)
    |> Enum.take(3)
    |> Enum.map(fn {day, n} -> "#{day} (#{n})" end)
  end

  defp recent_examples(events) do
    events
    |> Enum.reverse()
    |> Enum.take(@max_examples)
    |> Enum.reverse()
    |> Enum.map(&example_line/1)
  end

  defp example_line(e) do
    date = e.inserted_at |> NaiveDateTime.to_date() |> Date.to_iso8601()
    "#{date} #{e.event_type}"
  end

  defp day_from_event(e) do
    case Jason.decode(e.data) do
      {:ok, %{"slot_key" => sk}} -> sk |> String.split("_", parts: 2) |> hd()
      _ -> nil
    end
  end

  defp format_pct(rate), do: "#{round(rate * 100)}%"
end
