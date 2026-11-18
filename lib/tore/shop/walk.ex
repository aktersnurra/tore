defmodule Tore.Shop.Walk do
  @moduledoc """
  The order the household walks its store, learned from the order things get ticked off. No
  model is asked.

  Ticks on one list less than two hours apart are one trip. A trip counts when it took at least
  two minutes and covered two sections or more: ticking a whole list off at home afterwards
  takes seconds and says nothing about the store. Each counted trip ranks its sections by when
  they were first ticked. Once there are three such trips, a section's place is its average rank
  over the latest ten; a section never ticked keeps its place in the default walk. Other stays
  last.
  """

  import Ecto.Query

  alias Tore.{Repo, Scope, Shop}
  alias Tore.EventStore.Event

  @default ~w(produce bread meat fish deli dairy dry_goods canned herbs_spices condiments beverages household frozen other)a

  @trip_gap_seconds 2 * 60 * 60
  @min_trip_seconds 2 * 60
  @min_trips 3
  @latest_trips 10
  @history_days 12 * 7

  @type tick :: {NaiveDateTime.t(), String.t(), atom()}

  @doc "The default walk through a Swedish store: fruit and veg first, frozen by the tills."
  @spec default() :: [atom()]
  def default, do: @default

  @doc "The household's section order: learned from its trips once it has enough, else the default."
  @spec order(Scope.t()) :: [atom()]
  def order(%Scope{} = scope), do: scope |> ticks() |> learn()

  @doc """
  The section order from `ticks`, each `{at, list_id, section}`. Pure. The default until there
  are enough trips.
  """
  @spec learn([tick()]) :: [atom()]
  def learn(ticks) do
    trips =
      ticks
      |> Enum.group_by(&elem(&1, 1))
      |> Enum.flat_map(fn {_list, list_ticks} -> trips(list_ticks) end)
      |> Enum.filter(&counts?/1)
      |> Enum.sort_by(&(&1 |> hd() |> elem(0)), {:desc, NaiveDateTime})
      |> Enum.take(@latest_trips)

    if length(trips) < @min_trips, do: @default, else: rank(trips)
  end

  @doc """
  When the household's latest shopping trips began (UTC), newest first: the same trips the walk
  learns from, so ticking a list off at home afterwards isn't one.
  """
  @spec trip_starts(Scope.t()) :: [NaiveDateTime.t()]
  def trip_starts(%Scope{} = scope) do
    scope
    |> ticks()
    |> Enum.group_by(&elem(&1, 1))
    |> Enum.flat_map(fn {_list, list_ticks} -> trips(list_ticks) end)
    |> Enum.filter(&counts?/1)
    |> Enum.map(&(&1 |> hd() |> elem(0)))
    |> Enum.sort({:desc, NaiveDateTime})
    |> Enum.take(@latest_trips)
  end

  # A list's ticks, in time order, split wherever two are hours apart.
  defp trips(ticks) do
    ticks
    |> Enum.sort_by(&elem(&1, 0), NaiveDateTime)
    |> Enum.reduce([], fn
      tick, [[prev | _] = trip | done] ->
        if NaiveDateTime.diff(elem(tick, 0), elem(prev, 0)) > @trip_gap_seconds,
          do: [[tick], Enum.reverse(trip) | done],
          else: [[tick | trip] | done]

      tick, [] ->
        [[tick]]
    end)
    |> case do
      [] -> []
      [open | done] -> Enum.reverse([Enum.reverse(open) | done])
    end
  end

  defp counts?(trip) do
    {first, _, _} = hd(trip)
    {last, _, _} = List.last(trip)

    NaiveDateTime.diff(last, first) >= @min_trip_seconds and
      trip |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length() >= 2
  end

  # The ticked sections, by their average place across trips (0 first, 1 last), take over the
  # slots the default gives them; a section no trip ticked stays in its slot.
  defp rank(trips) do
    places =
      trips
      |> Enum.flat_map(fn trip ->
        sections = trip |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
        last = max(length(sections) - 1, 1)
        sections |> Enum.with_index() |> Enum.map(fn {s, i} -> {s, i / last} end)
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {s, ps} -> {s, Enum.sum(ps) / length(ps)} end)

    learned =
      Enum.sort_by(
        Map.keys(places),
        &{Map.fetch!(places, &1), Enum.find_index(@default, fn d -> d == &1 end)}
      )

    {order, []} =
      Enum.map_reduce(@default, learned, fn
        section, [next | rest] = queue ->
          if Map.has_key?(places, section), do: {next, rest}, else: {section, queue}

        section, [] ->
          {section, []}
      end)

    order
  end

  # The household's ticks of the last twelve weeks, each with the section its item was in.
  defp ticks(scope) do
    since = NaiveDateTime.add(NaiveDateTime.utc_now(), -@history_days, :day)

    checked =
      from(e in Event,
        where:
          e.stream_type == "shop" and e.event_type == "ItemChecked" and e.inserted_at >= ^since,
        order_by: [asc: e.id],
        select: {e.stream_id, e.data, e.inserted_at}
      )
      |> Repo.all(Scope.repo_opts(scope))

    sections =
      checked
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Map.new(fn list_id ->
        {:ok, list} = Shop.load_list(scope, list_id)
        {list_id, Map.new(list.items, fn {id, item} -> {id, item.section} end)}
      end)

    for {list_id, data, at} <- checked,
        %{"item_id" => item_id} = Jason.decode!(data),
        section = get_in(sections, [list_id, item_id]),
        section not in [nil, :other],
        do: {at, list_id, section}
  end
end
