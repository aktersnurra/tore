defmodule Tore.Mcp.Tools.GetPlanningHistory do
  @moduledoc """
  What the household actually planned, day by day, over the last six weeks and this one: the
  recipe each day ended with, whether it was eaten as leftovers or skipped, and what was swapped
  out on the way. Facts rather than statistics, so the agent finds the patterns itself (tacos on
  Fridays, Sunday's sauce eaten again on Monday).
  """
  @behaviour Tore.Mcp.Tool

  import Ecto.Query

  alias Tore.{Clock, EventStore, Repo, Scope, Streams}
  alias Tore.Planning.{Decider, Events}
  alias Tore.Recipes.Recipe

  @weeks 6
  @days ~w(mon tue wed thu fri sat sun)

  @impl true
  def name, do: "get_planning_history"

  @impl true
  def description,
    do: """
    Every planned day of the last six weeks and this one, oldest first: the recipe it ended \
    with, `leftovers` when it was eaten again from an earlier day, `skipped` (with `reason`, \
    `place` and `amount` when they ate out), and `swapped_out` for recipes planned there and \
    then replaced or removed.\
    """

  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def call(scope, _args) do
    this_monday = Streams.monday(Clock.today())
    mondays = for w <- @weeks..0//-1, into: %{}, do: week(scope, Date.add(this_monday, -7 * w))

    slots =
      from(e in EventStore.Event,
        where: e.stream_id in ^Map.keys(mondays),
        order_by: [asc: e.id]
      )
      |> Repo.all(Scope.repo_opts(scope))
      |> Enum.group_by(& &1.stream_id)
      |> Enum.flat_map(fn {stream, events} -> slots(mondays[stream], events) end)
      |> Enum.sort_by(& &1.date, Date)

    titles = titles(scope, slots)
    {:ok, %{days: Enum.map(slots, &day(&1, titles))}}
  end

  defp week(scope, monday), do: {Streams.plan(scope, monday), monday}

  # The week's final state from the decider, plus what each slot held before it was replaced
  # or removed, which the final state forgets.
  defp slots(monday, events) do
    {state, swapped} =
      Enum.reduce(events, {Decider.initial(), %{}}, fn raw, {state, swapped} ->
        event = Events.from_json(%{"type" => raw.event_type, "data" => Jason.decode!(raw.data)})
        {Decider.evolve(state, event), swap(swapped, state, event)}
      end)

    for key <- Enum.uniq(Map.keys(state.slots) ++ Map.keys(swapped)) do
      [day, _meal] = String.split(key, "_", parts: 2)
      offset = Enum.find_index(@days, &(&1 == day))

      %{
        date: Date.add(monday, offset),
        slot: key,
        now: Map.get(state.slots, key),
        swapped_out: swapped |> Map.get(key, []) |> Enum.reverse()
      }
    end
  end

  defp swap(swapped, state, %Events.RecipeAssigned{slot_key: key, recipe_id: new}),
    do: put_swapped(swapped, key, held(state, key), new)

  defp swap(swapped, state, %Events.RecipeRemoved{slot_key: key}),
    do: put_swapped(swapped, key, held(state, key), nil)

  defp swap(swapped, _state, _event), do: swapped

  defp held(state, key), do: get_in(state.slots, [key, :recipe_id])

  defp put_swapped(swapped, _key, nil, _new), do: swapped
  defp put_swapped(swapped, _key, same, same), do: swapped
  defp put_swapped(swapped, key, old, _new), do: Map.update(swapped, key, [old], &[old | &1])

  defp titles(scope, slots) do
    ids =
      Enum.flat_map(slots, fn slot -> [get_in(slot, [:now, :recipe_id]) | slot.swapped_out] end)

    from(r in Recipe, where: r.id in ^Enum.reject(ids, &is_nil/1), select: {r.id, r.title})
    |> Repo.all(Scope.repo_opts(scope))
    |> Map.new()
  end

  defp day(slot, titles) do
    now = slot.now || %{}
    title = &Map.get(titles, &1, "(deleted recipe)")

    %{date: Date.to_iso8601(slot.date), slot: slot.slot}
    |> put(:recipe, now[:recipe_id] && title.(now[:recipe_id]))
    |> put(:leftovers, now[:leftover] || nil)
    |> put(:skipped, now[:skipped] || nil)
    |> put(:reason, now[:reason])
    |> put(:place, now[:place])
    |> put(:amount, now[:amount])
    |> put(:swapped_out, if(slot.swapped_out != [], do: Enum.map(slot.swapped_out, title)))
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
