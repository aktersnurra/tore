defmodule Tore.HomeTest do
  use Tore.DataCase, async: false

  import Mox
  import Tore.RunFixtures

  alias Tore.{Home, Planning, Recipes, Shop, Streams}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.HomePick
  alias Tore.Harness.Kinds

  setup :set_mox_from_context
  setup :verify_on_exit!

  # Tuesday 10 November 2026, in the week of Monday the 9th.
  @tuesday_evening ~N[2026-11-10 17:00:00]
  @monday ~D[2026-11-09]

  defp facts(overrides) do
    Map.merge(
      %{
        now: @tuesday_evening,
        tonight: :planned,
        planned_this_week: 3,
        unplanned_this_week: 2,
        unplanned_next_week: 7,
        list_items: 4,
        items_left: 3,
        reviews: 0
      },
      Map.new(overrides)
    )
  end

  defp plan_tonight(scope) do
    {:ok, recipe} =
      Recipes.create(scope, %{title: "Lax", base_servings: 4, ingredients: []}, image: false)

    {:ok, _} =
      Planning.assign_recipe(scope, Streams.plan(scope, @monday), "tue_dinner", recipe.id, 4)

    recipe
  end

  defp stored_pick(scope, pick, applied_at \\ DateTime.utc_now()) do
    {:ok, run} = Runs.submit(scope, Kinds.HomePick, pick, %{})

    Repo.update_all(
      from(r in KitchenRun, where: r.id == ^run.id),
      [set: [applied_at: applied_at]],
      household_id: scope.household_id
    )

    run
  end

  describe "facts/2" do
    test "reads tonight, what's unplanned, the list and the reviews waiting" do
      scope = home_scope()
      plan_tonight(scope)

      stub(Tore.MockLLM, :text, fn _system, _user, _opts ->
        {:ok, %{"section" => "dairy"}, %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}}
      end)

      list_id = Streams.shop_list(scope, @monday)
      {:ok, _} = Shop.add_item(scope, list_id, "mjölk", Decimal.new(1), "l", nil)
      {:ok, _} = Shop.add_item(scope, list_id, "bröd", Decimal.new(1), "st", nil)
      {:ok, state} = Shop.load_list(scope, list_id)
      [item | _] = Map.values(state.items)
      {:ok, _} = Shop.check_item(scope, list_id, item.id, nil)
      pending_review_fixture(scope)

      assert %{
               tonight: :planned,
               planned_this_week: 1,
               unplanned_this_week: 5,
               unplanned_next_week: 7,
               list_items: 2,
               items_left: 1,
               reviews: 1
             } = Home.facts(scope, @tuesday_evening)
    end

    test "an empty week has nothing planned tonight" do
      assert %{tonight: :empty, planned_this_week: 0, list_items: 0, reviews: 0} =
               Home.facts(home_scope(), @tuesday_evening)
    end
  end

  describe "fallback/1" do
    test "a review waiting wins over every other rule" do
      assert %{screen: :review} =
               Home.fallback(facts(reviews: 1, now: ~N[2026-11-14 09:00:00]))
    end

    test "Saturday before two opens the list, after it tonight" do
      assert %{screen: :shop} = Home.fallback(facts(now: ~N[2026-11-14 13:59:00]))
      assert %{screen: :today} = Home.fallback(facts(now: ~N[2026-11-14 14:00:00]))
    end

    test "Sunday from four opens the plan" do
      assert %{screen: :today} = Home.fallback(facts(now: ~N[2026-11-15 15:59:00]))
      assert %{screen: :plan} = Home.fallback(facts(now: ~N[2026-11-15 16:00:00]))
    end

    test "otherwise tonight, with swaps to the other main screens and never its own" do
      assert %{screen: :today, swaps: [:open_plan, :open_shop]} = Home.fallback(facts([]))

      assert %{screen: :review, swaps: [:open_today, :open_plan, :open_shop]} =
               Home.fallback(facts(reviews: 2))
    end
  end

  describe "screens_for/1 and swaps_for/1" do
    test "leave out what makes no sense now" do
      refute :review in Home.screens_for(facts(reviews: 0))
      assert :review in Home.screens_for(facts(reviews: 1))
      refute :cooking in Home.screens_for(facts(tonight: :eating_out))

      none = Home.swaps_for(facts(tonight: :planned, unplanned_next_week: 0, reviews: 0))

      refute Enum.any?(
               [:open_review, :plan_next_week, :suggest_tonight, :build_list],
               &(&1 in none)
             )

      some = Home.swaps_for(facts(tonight: :empty, list_items: 0, planned_this_week: 2))
      assert :suggest_tonight in some
      assert :build_list in some
    end
  end

  describe "questions/1 and pick/2" do
    test "ask a choice among the screens that make sense and a yes/no per swap" do
      questions = Home.questions(facts(reviews: 0))

      assert %{"type" => "choice", "criteria" => criteria} = questions["screen"]
      refute Map.has_key?(criteria, "review")
      assert %{"type" => "noul", "instructions" => _} = questions["swap_open_shop"]
      refute Map.has_key?(questions, "swap_open_review")
    end

    test "a sure choice is used, with likely swaps best first, at most three, never its own screen" do
      answers = %{
        "screen" => %{"choice" => "shop", "confidence" => 0.8},
        "swap_open_shop" => %{"noul" => 0.99},
        "swap_open_plan" => %{"noul" => 0.6},
        "swap_open_today" => %{"noul" => 0.9},
        "swap_plan_next_week" => %{"noul" => 0.7},
        "swap_suggest_tonight" => %{"noul" => 0.95}
      }

      assert %HomePick{
               screen: :shop,
               source: :model,
               swaps: [:open_today, :plan_next_week, :open_plan]
             } = Home.pick(answers, facts([]))
    end

    test "an unsure answer, or a screen that makes no sense now, is the fixed rule's pick" do
      unsure = %{"screen" => %{"choice" => "shop", "confidence" => 0.5}}
      assert %HomePick{source: :rules, screen: :today} = Home.pick(unsure, facts([]))

      gone = %{"screen" => %{"choice" => "review", "confidence" => 0.9}}
      assert %HomePick{source: :rules} = Home.pick(gone, facts(reviews: 0))

      assert %HomePick{source: :rules} = Home.pick(%{}, facts([]))
    end
  end

  test "swap labels and requests are in the household's language" do
    Gettext.with_locale(ToreWeb.Gettext, "sv", fn ->
      assert %{label: "Inköpslistan", action: {:open, :shop}} = Home.swap(:open_shop)
      assert %{action: {:prompt, "Gör inköpslistan från veckans plan"}} = Home.swap(:build_list)
    end)
  end

  describe "current/2" do
    test "without a stored pick, the fixed rule's, and a new one is due" do
      assert %{screen: :today, stale?: true, swaps: swaps} =
               Home.current(home_scope(), @tuesday_evening)

      assert Enum.map(swaps, & &1.key) == [:open_plan, :open_shop]
      assert %{label: _, action: {:open, :plan}} = hd(swaps)
    end

    test "the latest applied pick wins, and a fresh one isn't stale" do
      scope = home_scope()

      stored_pick(
        scope,
        %HomePick{screen: :plan, source: :model, swaps: []},
        ~U[2026-01-01 00:00:00Z]
      )

      stored_pick(scope, %HomePick{screen: :costs, source: :model, swaps: [:open_shop]})

      assert %{screen: :costs, swaps: [%{key: :open_shop}], stale?: false} =
               Home.current(scope, @tuesday_evening)
    end

    test "a pick older than an hour is stale" do
      scope = home_scope()
      an_hour_ago = DateTime.add(DateTime.utc_now(), -3601)
      stored_pick(scope, %HomePick{screen: :plan, source: :model, swaps: []}, an_hour_ago)

      assert %{screen: :plan, stale?: true} = Home.current(scope, @tuesday_evening)
    end

    test "a run applied since the pick makes it stale" do
      scope = home_scope()

      stored_pick(
        scope,
        %HomePick{screen: :plan, source: :model, swaps: []},
        DateTime.add(DateTime.utc_now(), -60)
      )

      other = pending_review_fixture(scope)

      Repo.update_all(
        from(r in KitchenRun, where: r.id == ^other.id),
        [set: [status: :applied, applied_at: DateTime.utc_now(), undo: {:steps, []}]],
        household_id: scope.household_id
      )

      assert %{stale?: true} = Home.current(scope, @tuesday_evening)
    end

    test "a stored review that has since been handled opens on the fixed rule's screen" do
      scope = home_scope()

      stored_pick(scope, %HomePick{
        screen: :review,
        source: :model,
        swaps: [:open_review, :open_plan]
      })

      assert %{screen: :today, swaps: swaps} = Home.current(scope, @tuesday_evening)
      refute :open_review in Enum.map(swaps, & &1.key)
    end
  end

  describe "refresh/1" do
    test "starts a pick in the background, then not again within ten minutes" do
      scope = home_scope()
      Phoenix.PubSub.subscribe(Tore.PubSub, Runs.topic(scope))

      expect(Tore.MockLLM, :decide, fn _state, _questions, _opts ->
        {:ok, %{"screen" => %{"choice" => "plan", "confidence" => 0.9}},
         %{prompt_tokens: 10, completion_tokens: 0, cost_usd: 0.0}}
      end)

      assert :started = Home.refresh(scope)
      assert_receive {:run_changed, %KitchenRun{kind: "home_pick_run", status: :applied}}, 2000
      assert :skipped = Home.refresh(scope)
      assert %{screen: :plan, stale?: false} = Home.current(scope)
    end

    test "never starts without AI" do
      unsponsored = scope_fixture(household_fixture())
      assert :skipped = Home.refresh(unsponsored)
      refute Repo.exists?(KitchenRun, household_id: unsponsored.household_id)
    end
  end
end
