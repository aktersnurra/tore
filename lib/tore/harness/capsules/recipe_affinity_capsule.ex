defmodule Tore.Harness.Capsules.RecipeAffinityCapsule do
  @moduledoc """
  Recipes the household chose recently or repeatedly, and recipes that were
  swapped out or removed. Derived from the planning event stream over the same
  window as `RecentHistoryCapsule`.

  A `RecipeAssigned` event counts as an affinity signal. A `RecipeRemoved`
  with no surrounding `RecipeAssigned` on the same slot key in the same week is
  treated as a dislike signal. The capsule caps both lists to keep the prompt
  compact.
  """

  @behaviour Tore.Harness.Capsule

  import Ecto.Query
  alias Tore.{EventStore, Repo}
  alias Tore.Recipes.Recipe

  @window_days 42
  @max_favorites 10
  @max_dislikes 10

  defstruct [:favorites, :dislikes, :total_assigned, :total_removed]

  @type entry :: %{recipe_id: integer(), title: String.t(), count: pos_integer()}

  @type t :: %__MODULE__{
          favorites: [entry()],
          dislikes: [entry()],
          total_assigned: non_neg_integer(),
          total_removed: non_neg_integer()
        }

  @impl true
  def build(ctx) do
    scope = Tore.Scope.for_household(ctx.household_id)

    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@window_days * 86_400, :second)
      |> DateTime.to_naive()

    events =
      from(e in EventStore.Event,
        where:
          e.stream_type == "planning" and e.inserted_at >= ^cutoff and
            e.event_type in ["RecipeAssigned", "RecipeRemoved"],
        order_by: [asc: e.id]
      )
      |> Repo.all(Tore.Scope.repo_opts(scope))

    {assigned_ids, removed_ids} = partition_recipe_ids(scope, events)
    titles = title_map(scope, assigned_ids ++ removed_ids)

    %__MODULE__{
      favorites: rank(assigned_ids, titles, @max_favorites),
      dislikes: rank(removed_ids, titles, @max_dislikes),
      total_assigned: length(assigned_ids),
      total_removed: length(removed_ids)
    }
  end

  @impl true
  def to_prompt(%__MODULE__{favorites: [], dislikes: []}), do: nil

  def to_prompt(%__MODULE__{} = c) do
    fav = format_section("Frequently chosen", c.favorites, c.total_assigned, @max_favorites)
    dis = format_section("Removed or swapped out", c.dislikes, c.total_removed, @max_dislikes)

    [fav, dis] |> Enum.reject(&is_nil/1) |> Enum.join("\n\n")
  end

  defp partition_recipe_ids(scope, events) do
    Enum.reduce(events, {[], []}, fn e, {assigned, removed} ->
      case {e.event_type, recipe_id_from(e)} do
        {"RecipeAssigned", id} when is_integer(id) -> {[id | assigned], removed}
        # RecipeRemoved doesn't carry recipe_id, so we infer it by looking up the
        # most-recent RecipeAssigned on the same slot_key within the window.
        {"RecipeRemoved", _} -> {assigned, [{:slot, slot_key_from(e), e.id} | removed]}
        _ -> {assigned, removed}
      end
    end)
    |> resolve_removed(scope)
  end

  defp resolve_removed({assigned, removed_slots}, scope) do
    removed = removed_slots |> Enum.map(&removed_recipe_id(scope, &1)) |> Enum.reject(&is_nil/1)
    {Enum.reverse(assigned), removed}
  end

  defp removed_recipe_id(_scope, {:slot, nil, _}), do: nil

  defp removed_recipe_id(scope, {:slot, slot_key, before_id}) do
    from(e in EventStore.Event,
      where:
        e.stream_type == "planning" and e.event_type == "RecipeAssigned" and
          e.id < ^before_id,
      order_by: [desc: e.id],
      limit: 1
    )
    |> Repo.all(Tore.Scope.repo_opts(scope))
    |> Enum.find_value(fn raw ->
      case Jason.decode(raw.data) do
        {:ok, %{"slot_key" => ^slot_key, "recipe_id" => rid}} when is_integer(rid) -> rid
        _ -> nil
      end
    end)
  end

  defp recipe_id_from(e) do
    case Jason.decode(e.data) do
      {:ok, %{"recipe_id" => rid}} when is_integer(rid) -> rid
      _ -> nil
    end
  end

  defp slot_key_from(e) do
    case Jason.decode(e.data) do
      {:ok, %{"slot_key" => sk}} -> sk
      _ -> nil
    end
  end

  defp title_map(_scope, []), do: %{}

  defp title_map(scope, ids) do
    unique = ids |> Enum.uniq()

    from(r in Recipe, where: r.id in ^unique, select: {r.id, r.title})
    |> Repo.all(Tore.Scope.repo_opts(scope))
    |> Map.new()
  end

  defp rank(ids, titles, limit) do
    ids
    |> Enum.frequencies()
    |> Enum.map(fn {id, n} ->
      %{recipe_id: id, title: Map.get(titles, id, "(unknown)"), count: n}
    end)
    |> Enum.sort_by(& &1.count, :desc)
    |> Enum.take(limit)
  end

  defp format_section(_label, [], _total, _limit), do: nil

  defp format_section(label, entries, total, limit) do
    shown = length(entries)

    suffix =
      if total > shown,
        do: " (top #{limit} of #{total} events)",
        else: ""

    lines =
      Enum.map_join(entries, "\n", fn %{title: t, count: n} -> "  - #{t} (#{n}x)" end)

    "#{label}#{suffix}:\n#{lines}"
  end
end
