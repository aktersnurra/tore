defmodule Tore.Budget.ForecastTest do
  use Tore.DataCase, async: false

  import Ecto.Query

  alias Tore.{Budget, Planning, Recipes, Streams}
  alias Tore.Budget.Forecast
  alias Tore.Budget.Forecast.{Baseline, Facts, OpenDays}
  alias Tore.EventStore.Event
  alias Tore.Costs.Receipt
  alias Tore.Recipes.Ingredient

  @week ~D[2026-11-16]
  @today ~D[2026-11-20]

  defp d(s), do: Decimal.new(s)
  defp opts, do: Tore.Scope.repo_opts(home_scope())

  # A recipe for 4 whose one ingredient is estimated at `kr` per item.
  defp recipe(title, kr) do
    {:ok, recipe} =
      Recipes.create(
        home_scope(),
        %{
          title: title,
          recipe_type: :meal,
          base_servings: 4,
          ingredients: [%{name: title <> " i", quantity: 1, unit: "st"}]
        },
        image: false
      )

    Repo.update_all(
      from(i in Ingredient, where: i.name == ^(title <> " i")),
      [set: [estimated_price: d(kr), estimated_unit: "st"]],
      opts()
    )

    recipe
  end

  defp receipt(week, kr, lines \\ []) do
    {:ok, _} =
      Tore.Costs.log_receipt(home_scope(), %{
        date: week,
        week_start: week,
        store_name: "ICA",
        total_amount: d(kr),
        user_id: user_fixture().id,
        line_items: lines
      })
  end

  # Moves what was stored for `week` (its plan's events and its receipts) back to `at`.
  defp stored_at(week, at) do
    Repo.update_all(
      from(e in Event, where: e.stream_id == ^Streams.plan(home_scope(), week)),
      [set: [inserted_at: at]],
      opts()
    )

    Repo.update_all(
      from(r in Receipt, where: r.week_start == ^week),
      [set: [inserted_at: at]],
      opts()
    )
  end

  # Weeks of Monday's stew and six open days, each paid 700 kr: the stew and six more like it.
  defp stew_weeks(stew, weeks) do
    for week <- weeks do
      {:ok, _} =
        Planning.assign_recipe(
          home_scope(),
          Streams.plan(home_scope(), week),
          "mon_dinner",
          stew.id,
          4
        )

      receipt(week, "700")
      stored_at(week, NaiveDateTime.new!(Date.add(week, -2), ~T[12:00:00]))
    end
  end

  test "the live rung is what the budget expects" do
    stew = recipe("Gryta", "100")
    stew_weeks(stew, [Date.add(@week, -14), Date.add(@week, -7)])

    {:ok, _} =
      Planning.assign_recipe(
        home_scope(),
        Streams.plan(home_scope(), @week),
        "tue_dinner",
        stew.id,
        8
      )

    status = Budget.status(home_scope(), @week)
    prediction = Forecast.predict(home_scope(), @week, NaiveDateTime.utc_now())

    assert %{expected: expected, low: nil, high: nil} = prediction
    assert Decimal.eq?(expected, status.expected)
    # Tuesday's stew for 8, 200 kr, and six open days at the median dinner, 100 kr each.
    assert Decimal.eq?(expected, 800)
  end

  test "the baseline counts no open days; open days count a typical dinner each" do
    stew = recipe("Gryta", "100")

    {:ok, _} =
      Planning.assign_recipe(
        home_scope(),
        Streams.plan(home_scope(), @week),
        "mon_dinner",
        stew.id,
        4
      )

    facts = Facts.load(home_scope(), @week, NaiveDateTime.utc_now())

    assert Decimal.eq?(Baseline.predict(facts).expected, 100)
    assert Decimal.eq?(OpenDays.predict(facts).expected, 700)
  end

  test "what Tore learned after as_of never reaches the facts" do
    stew = recipe("Gryta", "100")
    soup = recipe("Soppa", "40")
    stew_weeks(stew, [Date.add(@week, -21), Date.add(@week, -14), Date.add(@week, -7)])

    {:ok, _} =
      Planning.assign_recipe(
        home_scope(),
        Streams.plan(home_scope(), @week),
        "mon_dinner",
        soup.id,
        4
      )

    stored_at(@week, ~N[2026-11-15 12:00:00])

    as_of = ~N[2026-11-16 00:00:00]
    later = ~N[2026-11-17 09:00:00]
    # Offers count from a store the household shops at.
    store = Repo.insert!(%Tore.Deals.Store{name: "ICA Maxi", url: "https://example.test/maxi"})

    Repo.insert!(%Tore.Deals.HouseholdStore{
      household_id: home_scope().household_id,
      store_id: store.id
    })

    # A receipt's line reaches the stew's ingredient through a match, as it would in the app.
    stew_i = Repo.get_by!(Ingredient, [name: "Gryta i"], opts())
    Tore.Prices.Products.put(home_scope(), "Gryta i", stew_i.id)

    known = Facts.load(home_scope(), @week, as_of)
    :rand.seed(:exsss, {7, 11, 13})

    weeks = [Date.add(@week, -21), Date.add(@week, -14), Date.add(@week, -7), @week]
    slots = ~w(mon_dinner tue_dinner wed_dinner sat_lunch sun_dinner)

    # Each round adds one late fact at random: a receipt with a price on it, a change to a plan,
    # an offer on what a dinner needs, a day off.
    for round <- 1..30 do
      week = Enum.random(weeks)

      case :rand.uniform(4) do
        1 ->
          receipt(week, to_string(100 + :rand.uniform(900)), [
            %{
              product_name: "Gryta i",
              quantity: d(1),
              unit: "st",
              total_price: d(:rand.uniform(300))
            }
          ])

          Repo.update_all(
            from(r in Receipt, where: r.inserted_at > ^later),
            [set: [inserted_at: later]],
            opts()
          )

        2 ->
          id = Enum.random([stew.id, soup.id])
          plan = Streams.plan(home_scope(), week)

          {:ok, _} =
            Planning.assign_recipe(
              home_scope(),
              plan,
              Enum.random(slots),
              id,
              2 + :rand.uniform(6)
            )

          Repo.update_all(
            from(e in Event, where: e.inserted_at > ^later),
            [set: [inserted_at: later]],
            opts()
          )

        3 ->
          {:ok, _} =
            Tore.Deals.upsert_deals([
              %{
                chain: "ica",
                store: "ICA Maxi",
                quantity: 1,
                product_name: "Soppa i #{round}",
                price: d(:rand.uniform(50)),
                price_unit: "st",
                regular_price: d(60),
                valid_until: Date.add(@week, 6)
              }
            ])

          Tore.Prices.Products.put(
            home_scope(),
            "Soppa i #{round}",
            Repo.get_by!(Ingredient, [name: "Soppa i"], opts()).id
          )

          Repo.update_all(from(x in Tore.Deals.Deal, where: x.inserted_at > ^later),
            set: [inserted_at: later]
          )

        4 ->
          :ok = Planning.mark_days_off(home_scope(), [Date.add(week, :rand.uniform(7) - 1)])

          Repo.update_all(
            from(e in Event, where: e.inserted_at > ^later),
            [set: [inserted_at: later]],
            opts()
          )
      end

      assert Facts.load(home_scope(), @week, as_of) == known, "round #{round} leaked"
    end

    # The same facts, known in time, do count.
    refute Facts.load(home_scope(), @week, later) == known
  end

  test "the backtest scores each rung on the weeks paid for, as each stood on its Monday" do
    stew = recipe("Gryta", "100")
    weeks = for n <- 4..1//-1, do: Date.add(@week, -7 * n)
    stew_weeks(stew, weeks)

    scores = Forecast.backtest(home_scope(), today: @today)

    # The first two weeks have too little history to calibrate on: the baseline says the stew,
    # 100 kr, and is 600 off; with open days it says 700. After that both say 700.
    assert %{weeks: 4, mae: base_mae, coverage: nil} = scores[Baseline]
    assert %{weeks: 4, mae: open_mae, coverage: nil} = scores[OpenDays]
    assert Decimal.eq?(base_mae, 300)
    assert Decimal.eq?(open_mae, 0)
  end

  test "a week still being shopped for isn't scored" do
    receipt(@week, "300")
    assert %{weeks: 0, mae: nil} = Forecast.backtest(home_scope(), today: @today)[OpenDays]
  end
end
