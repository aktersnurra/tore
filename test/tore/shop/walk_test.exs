defmodule Tore.Shop.WalkTest do
  use Tore.DataCase, async: false

  import Ecto.Query

  alias Tore.Shop
  alias Tore.Shop.{Commands, Walk}
  alias Tore.EventStore.Event

  # A trip on its own list: the sections ticked two minutes apart, starting at `day`.
  defp trip(day, sections) do
    start = NaiveDateTime.new!(day, ~T[17:00:00])

    for {section, i} <- Enum.with_index(sections),
        do: {NaiveDateTime.add(start, 120 * i), "list-#{day}", section}
  end

  defp ice_cream_first(n),
    do: for(d <- 1..n, do: trip(Date.new!(2026, 10, d), [:frozen, :produce, :dairy]))

  describe "learn/1" do
    test "the default walk until there are three trips" do
      assert Walk.learn(List.flatten(ice_cream_first(2))) == Walk.default()
    end

    test "three trips that start in frozen put frozen first, other last" do
      order = Walk.learn(List.flatten(ice_cream_first(3)))

      assert hd(order) == :frozen

      assert Enum.filter(order, &(&1 in [:frozen, :produce, :dairy])) == [
               :frozen,
               :produce,
               :dairy
             ]

      assert List.last(order) == :other
      assert Enum.sort(order) == Enum.sort(Walk.default())
    end

    test "ticking a list off at home in seconds teaches nothing" do
      at_home =
        for d <- 1..5 do
          start = NaiveDateTime.new!(Date.new!(2026, 10, d), ~T[20:00:00])

          for {s, i} <- Enum.with_index([:frozen, :dairy]),
              do: {NaiveDateTime.add(start, i), "l#{d}", s}
        end

      assert Walk.learn(List.flatten(at_home)) == Walk.default()
    end

    test "ticks hours apart on one list are two trips" do
      day = ~D[2026-10-01]
      morning = trip(day, [:frozen, :produce])

      evening =
        for {at, _, s} <- trip(day, [:frozen, :produce]),
            do: {NaiveDateTime.add(at, 5 * 3600), "list-#{day}", s}

      later = trip(~D[2026-10-02], [:frozen, :produce])

      assert hd(Walk.learn(morning ++ evening ++ later)) == :frozen
    end

    test "a section no trip ticked keeps its default slot" do
      order = Walk.learn(List.flatten(ice_cream_first(3)))

      for s <- Walk.default() -- [:frozen, :produce, :dairy],
          do:
            assert(
              Enum.find_index(order, &(&1 == s)) == Enum.find_index(Walk.default(), &(&1 == s))
            )
    end
  end

  describe "order/1" do
    test "learns from the household's ticks" do
      scope = home_scope()

      for d <- 1..3 do
        week = Date.add(Tore.Streams.monday(Tore.Clock.today()), -7 * d)
        list = Tore.Streams.shop_list(scope, week)

        items =
          for {name, section} <- [{"Glass", "frozen"}, {"Äpple", "produce"}, {"Mjölk", "dairy"}],
              do: %{
                "id" => "#{name}-#{d}",
                "name" => name,
                "quantity" => nil,
                "unit" => nil,
                "section" => section,
                "checked" => false,
                "basic" => false
              }

        {:ok, _} = Shop.append(scope, list, %Commands.BuildList{week_start: week, items: items})

        for {item, i} <- Enum.with_index(items) do
          {:ok, _} = Shop.append(scope, list, %Commands.CheckItem{item_id: item["id"]})
          at = NaiveDateTime.new!(Date.add(week, 4), Time.new!(17, i, 0))

          from(e in Event,
            where:
              e.stream_id == ^list and e.event_type == "ItemChecked" and
                like(e.data, ^"%#{item["id"]}%")
          )
          |> Repo.update_all([set: [inserted_at: at]], Tore.Scope.repo_opts(scope))
        end
      end

      order = Walk.order(scope)
      assert hd(order) == :frozen

      assert Enum.filter(order, &(&1 in [:frozen, :produce, :dairy])) == [
               :frozen,
               :produce,
               :dairy
             ]
    end
  end
end
