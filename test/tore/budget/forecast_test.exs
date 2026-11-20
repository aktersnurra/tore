defmodule Tore.Budget.ForecastTest do
  use Tore.DataCase, async: false

  import Ecto.Query

  alias Tore.{Budget, Planning, Recipes, Streams}
  alias Tore.Budget.Forecast
  alias Tore.Budget.Forecast.{Baseline, Drift, Facts, OpenDays, PerLine, ScaleOffset, Simulation}

  import Tore.BudgetFixtures, only: [one_dinner: 3, scaled_weeks: 3]
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
    # Every week paid what open days said, so scale and offset says it too, inside its range.
    assert %{weeks: 4, mae: scaled_mae, coverage: 1.0} = scores[ScaleOffset]
    assert Decimal.eq?(scaled_mae, 0)
  end

  describe "scale and offset" do
    test "with nothing to learn from, says what open days say, with a range around it" do
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
      %{expected: expected, low: low, high: high} = ScaleOffset.predict(facts)

      assert Decimal.eq?(expected, OpenDays.predict(facts).expected)
      assert Decimal.lt?(low, expected) and Decimal.gt?(high, expected)
    end

    test "learns that the household pays more than its dinners in proportion" do
      scaled_weeks(
        home_scope(),
        @week,
        for(kr <- [450, 250, 350, 150, 400, 200, 300, 100], do: {kr, 0})
      )

      one_dinner(home_scope(), @week, recipe("Fest", "600"))

      facts = Facts.load(home_scope(), @week, NaiveDateTime.utc_now())
      # Paid as the weeks before it, 600 kr of dinner costs 1000 kr; open days says 850.
      truth = Decimal.new(1000)
      off = fn %{expected: e} -> e |> Decimal.sub(truth) |> Decimal.abs() end
      scaled = ScaleOffset.predict(facts)

      assert Decimal.lt?(off.(scaled), off.(OpenDays.predict(facts)))
      assert Decimal.lt?(scaled.low, truth) and Decimal.gt?(scaled.high, truth)
    end
  end

  describe "drift" do
    test "with nothing to learn from, says what open days say, with a range around it" do
      one_dinner(home_scope(), @week, recipe("Gryta", "100"))
      facts = Facts.load(home_scope(), @week, NaiveDateTime.utc_now())
      %{expected: expected, low: low, high: high} = Drift.predict(facts)

      assert Decimal.eq?(expected, OpenDays.predict(facts).expected)
      assert Decimal.lt?(low, expected) and Decimal.gt?(high, expected)
    end

    test "follows a shop that grows dearer week by week" do
      prices = [300, 200, 350, 250, 400, 150, 300, 250]
      # 40 kr more each week, newest first.
      scaled_weeks(home_scope(), @week, Enum.zip(prices, [280, 240, 200, 160, 120, 80, 40, 0]))
      one_dinner(home_scope(), @week, recipe("Fest", "300"))

      facts = Facts.load(home_scope(), @week, NaiveDateTime.utc_now())
      # 300 kr of dinner, half as much again, 100 kr and this week's 320 kr more.
      truth = Decimal.new(870)
      off = fn %{expected: e} -> e |> Decimal.sub(truth) |> Decimal.abs() end
      drift = Drift.predict(facts)

      # Scale and offset weighs the old, cheaper weeks as much as the new ones.
      assert Decimal.lt?(off.(drift), off.(ScaleOffset.predict(facts)))
      assert Decimal.lt?(drift.low, truth) and Decimal.gt?(drift.high, truth)
    end
  end

  describe "per line" do
    # Monday's stew and Tuesday's saffron bun for `buns` (4 is 50 kr), eating out the rest.
    defp stew_and_buns(week, stew, buns, servings) do
      plan = Streams.plan(home_scope(), week)
      {:ok, _} = Planning.assign_recipe(home_scope(), plan, "mon_dinner", stew.id, 4)
      {:ok, _} = Planning.assign_recipe(home_scope(), plan, "tue_dinner", buns.id, servings)

      for day <- ~w(wed thu fri sat sun) do
        {:ok, _} = Planning.eat_out(home_scope(), plan, day <> "_dinner", %{})
      end
    end

    test "with nothing to learn from, says what open days say, with a range around it" do
      one_dinner(home_scope(), @week, recipe("Gryta", "100"))
      facts = Facts.load(home_scope(), @week, NaiveDateTime.utc_now())
      %{expected: expected, low: low, high: high} = PerLine.predict(facts)

      assert Decimal.eq?(expected, OpenDays.predict(facts).expected)
      assert Decimal.lt?(low, expected) and Decimal.gt?(high, expected)
    end

    test "a line the household never buys counts for little" do
      stew = recipe("Gryta", "100")
      buns = recipe("Saffran", "50")
      stew_i = Repo.get_by!(Ingredient, [name: "Gryta i"], opts())
      Tore.Prices.Products.put(home_scope(), "Gryta i", stew_i.id)

      # Four weeks that bought the stew and 50 kr of other things, never the saffron.
      for n <- 1..4, week = Date.add(@week, -7 * n) do
        stew_and_buns(week, stew, buns, 4)

        receipt(week, "150", [
          %{product_name: "Gryta i", quantity: d(1), unit: "st", total_price: d(100)}
        ])
      end

      # Twice the buns this week: open days counts 200 kr, but the shop will be 150 kr again.
      stew_and_buns(@week, stew, buns, 8)
      facts = Facts.load(home_scope(), @week, NaiveDateTime.utc_now())
      off = fn %{expected: e} -> e |> Decimal.sub(150) |> Decimal.abs() end

      assert Decimal.eq?(OpenDays.predict(facts).expected, 200)
      assert Decimal.lt?(off.(PerLine.predict(facts)), off.(OpenDays.predict(facts)))
    end
  end

  describe "simulation" do
    setup do
      stew = recipe("Gryta", "100")

      {:ok, _} =
        Planning.assign_recipe(
          home_scope(),
          Streams.plan(home_scope(), @week),
          "mon_dinner",
          stew.id,
          4
        )

      %{facts: Facts.load(home_scope(), @week, NaiveDateTime.utc_now())}
    end

    test "the same facts give the same runs, whenever they are read", %{facts: facts} do
      assert Simulation.predict(facts) == Simulation.predict(facts)

      assert Simulation.predict(facts) ==
               Simulation.predict(%{facts | as_of: NaiveDateTime.add(facts.as_of, 60)})
    end

    test "with nothing to learn from, lands about where open days does", %{facts: facts} do
      %{expected: expected, low: low, high: high, draws: draws} = Simulation.predict(facts)

      # The stew, and six open days at the one dinner known, 100 kr each; extras average nothing.
      assert Decimal.lt?(Decimal.abs(Decimal.sub(expected, 700)), 15)
      assert Decimal.lt?(low, expected) and Decimal.gt?(high, expected)
      assert length(draws) == 2000
    end

    test "says how likely the week is to go over its budget" do
      plan = Planning.load_plan(home_scope(), Streams.plan(home_scope(), @week)) |> elem(1)

      risk = fn kr ->
        :ok = Budget.set_week(home_scope(), @week, Decimal.new(kr))
        Budget.status(home_scope(), plan, @week, Simulation).risk
      end

      assert risk.(10_000) == 0.0
      assert risk.(1) == 1.0
      assert risk.(700) > 0.3 and risk.(700) < 0.7
      assert Budget.status(home_scope(), plan, @week).risk == nil
    end
  end

  describe "the gate" do
    test "a rung goes live when it beats the one below and its range holds about 80 %" do
      below = %{weeks: 10, mae: Decimal.new(60), coverage: nil}

      assert Forecast.beats?(%{weeks: 10, mae: Decimal.new(50), coverage: 0.8}, below)
      assert Forecast.beats?(%{weeks: 10, mae: Decimal.new(50), coverage: 0.7}, below)
      # Worse, or no better.
      refute Forecast.beats?(%{weeks: 10, mae: Decimal.new(60), coverage: 0.8}, below)
      # A range that always holds is too wide to say anything; one that rarely does, too narrow.
      refute Forecast.beats?(%{weeks: 10, mae: Decimal.new(50), coverage: 1.0}, below)
      refute Forecast.beats?(%{weeks: 10, mae: Decimal.new(50), coverage: 0.6}, below)
      # Too few weeks to tell.
      refute Forecast.beats?(%{weeks: 7, mae: Decimal.new(50), coverage: 0.8}, below)
    end

    test "with little history the open-days rung stays live" do
      stew_weeks(recipe("Gryta", "100"), for(n <- 4..1//-1, do: Date.add(@week, -7 * n)))
      assert Forecast.live(home_scope(), today: @today) == OpenDays
    end

    test "the ladder is climbed while each rung beats the one below for long enough" do
      scaled_weeks(home_scope(), @week, Tore.BudgetFixtures.noisy_weeks())
      scores = Forecast.backtest(home_scope(), today: @today, weeks: 12)

      assert Forecast.beats?(scores[ScaleOffset], scores[OpenDays])
      assert Forecast.beats?(scores[Drift], scores[ScaleOffset])
      assert Forecast.live(home_scope(), today: @today) == Drift
    end
  end

  test "a week still being shopped for isn't scored" do
    receipt(@week, "300")
    assert %{weeks: 0, mae: nil} = Forecast.backtest(home_scope(), today: @today)[OpenDays]
  end
end
