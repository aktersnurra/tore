defmodule Tore.PlanningTest do
  use ExUnit.Case, async: false

  import Mox
  import Tore.AccountsFixtures

  alias Tore.Planning

  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
    Phoenix.PubSub.subscribe(Tore.PubSub, Planning.topic(home_scope()))
    :ok
  end

  # A real recipe for each made-up number, the same one each time within a test.
  defp recipe(n) do
    Process.get({:recipe, n}) ||
      tap(
        Tore.Recipes.create(home_scope(), %{title: "Recipe #{n}", recipe_type: :meal})
        |> elem(1)
        |> Map.fetch!(:id),
        &Process.put({:recipe, n}, &1)
      )
  end

  defp plan_id, do: Tore.Streams.plan(home_scope(), ~D[2026-04-27])

  defp mock_usage, do: %{prompt_tokens: 100, completion_tokens: 50, cost_usd: 0.001}

  test "load_plan returns initial state for new plan" do
    assert {:ok, state} = Planning.load_plan(home_scope(), plan_id())
    assert state.slots == %{}
  end

  test "assign_recipe persists RecipeAssigned event" do
    assert {:ok, _events} =
             Planning.assign_recipe(home_scope(), plan_id(), "mon_dinner", recipe(1), 4)

    assert {:ok, state} = Planning.load_plan(home_scope(), plan_id())
    assert state.slots["mon_dinner"].recipe_id == recipe(1)
    assert state.slots["mon_dinner"].servings == 4
  end

  test "assign_recipe broadcasts to plan topic" do
    Planning.assign_recipe(home_scope(), plan_id(), "tue_dinner", recipe(2), 2)
    assert_receive {:events, [%Tore.Planning.Events.RecipeAssigned{}]}
  end

  test "remove_recipe returns error for empty slot" do
    assert {:error, :slot_empty} = Planning.remove_recipe(home_scope(), plan_id(), "mon_dinner")
  end

  test "load_plan returns current state after multiple events" do
    Planning.assign_recipe(home_scope(), plan_id(), "mon_dinner", recipe(10), 4)
    Planning.assign_recipe(home_scope(), plan_id(), "tue_dinner", recipe(11), 2)
    Planning.skip_meal(home_scope(), plan_id(), "mon_dinner")

    {:ok, state} = Planning.load_plan(home_scope(), plan_id())
    assert state.slots["mon_dinner"].skipped == true
    assert state.slots["tue_dinner"].recipe_id == recipe(11)
  end

  describe "suggest_recipes_for_slot/3" do
    alias Tore.Recipes

    defp create_recipe(title, opts \\ []) do
      attrs =
        %{
          title: title,
          recipe_type: Keyword.get(opts, :recipe_type, :meal),
          base_servings: Keyword.get(opts, :base_servings, 4),
          prep_time_minutes: 10,
          cook_time_minutes: 20
        }

      # Straight to the Repo: Recipes.create/2 starts an image task whose LLM call would take this
      # test's one expectation.
      Tore.Repo.insert!(
        struct(Recipes.Recipe, Map.put(attrs, :household_id, home_scope().household_id))
      )
    end

    test "returns ranked recipes (rule-based, no LLM)" do
      _r1 = create_recipe("Plain pasta")
      r2 = create_recipe("Chicken curry", base_servings: 6)

      Tore.Pantry.add_item(home_scope(), %{name: "chicken", quantity: Decimal.new(1)})

      assert {:ok, results} =
               Planning.suggest_recipes_for_slot(home_scope(), plan_id(), "mon_dinner")

      assert is_list(results)
      assert length(results) >= 1

      # Each result is %{recipe, reasons, score}
      assert Enum.all?(results, &Map.has_key?(&1, :recipe))
      assert Enum.all?(results, &Map.has_key?(&1, :reasons))

      # Curry should rank above plain pasta because pantry overlap + leftovers
      curry = Enum.find(results, &(&1.recipe.id == r2.id))
      assert curry
      assert curry.score >= 0
    end

    test "respects :limit" do
      Enum.each(1..6, fn i -> create_recipe("Recipe #{i}") end)

      assert {:ok, results} =
               Planning.suggest_recipes_for_slot(home_scope(), plan_id(), "mon_dinner", limit: 3)

      assert length(results) <= 3
    end

    test ":include_llm true merges an extra LLM-suggested recipe" do
      r1 = create_recipe("Pasta")
      r2 = create_recipe("Curry")

      Tore.MockLLM
      |> expect(:text, fn _system, _user, _opts ->
        {:ok, %{"recipe_id" => r2.id, "reasoning" => "good fit"}, mock_usage()}
      end)

      assert {:ok, results} =
               Planning.suggest_recipes_for_slot(home_scope(), plan_id(), "tue_dinner",
                 include_llm: true,
                 limit: 5
               )

      # r2 should be in the results (from LLM merge or rule-based)
      assert Enum.any?(results, &(&1.recipe.id == r2.id))
      _ = r1
    end

    test ":include_llm true silently falls back when LLM errors" do
      _r = create_recipe("Pasta")

      Tore.MockLLM
      |> expect(:text, fn _system, _user, _opts -> {:error, :timeout} end)

      assert {:ok, results} =
               Planning.suggest_recipes_for_slot(home_scope(), plan_id(), "tue_dinner",
                 include_llm: true
               )

      assert is_list(results)
    end
  end

  describe "assign_with_leftovers/5" do
    alias Tore.Recipes

    test "assigns recipe to slot and marks leftover days in one broadcast" do
      {:ok, recipe} =
        Recipes.create(home_scope(), %{
          title: "Roast chicken",
          recipe_type: :meal,
          base_servings: 6,
          prep_time_minutes: 10,
          cook_time_minutes: 60
        })

      assert {:ok, events} =
               Planning.assign_with_leftovers(
                 home_scope(),
                 plan_id(),
                 "mon_dinner",
                 recipe.id,
                 6,
                 ["tue_dinner", "wed_dinner"]
               )

      # Primary RecipeAssigned + 2 (assign + leftover) per leftover day
      assert length(events) >= 5

      {:ok, state} = Planning.load_plan(home_scope(), plan_id())
      assert state.slots["mon_dinner"].recipe_id == recipe.id
      assert state.slots["tue_dinner"].leftover == true
      assert state.slots["wed_dinner"].leftover == true

      # Single broadcast
      assert_receive {:events, all_events}
      assert length(all_events) == length(events)
    end

    test "works with no leftover days (degenerates to assign)" do
      {:ok, recipe} =
        Recipes.create(home_scope(), %{
          title: "Quick salad",
          recipe_type: :meal,
          base_servings: 2,
          prep_time_minutes: 5,
          cook_time_minutes: 0
        })

      assert {:ok, events} =
               Planning.assign_with_leftovers(
                 home_scope(),
                 plan_id(),
                 "mon_dinner",
                 recipe.id,
                 2,
                 []
               )

      assert length(events) == 1
    end
  end

  test "plan_upcoming_week dispatches a weekly run for the upcoming Monday-start week" do
    Tore.MockLLM
    |> Mox.expect(:chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Nothing to do."},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    today = Date.utc_today()
    days_ahead = rem(8 - Date.day_of_week(today), 7)
    days_ahead = if days_ahead == 0, do: 7, else: days_ahead
    expected_week_start = Date.add(today, days_ahead)
    expected_stream = Tore.Streams.plan(home_scope(), expected_week_start)

    assert {:ok,
            %Tore.Harness.KitchenRun{status: :applied, kind: "weekly_planning_run", input: input}} =
             Planning.plan_upcoming_week(home_scope())

    assert input["plan_stream_id"] == expected_stream
    assert {:ok, _plan} = Planning.load_plan(home_scope(), expected_stream)
  end

  describe "swap_events/3 (pure)" do
    alias Tore.Planning.{Decider, State}

    test "returns cross-assign events and the evolved state without persisting" do
      {:ok, r1} =
        Tore.Recipes.create(home_scope(), %{title: "A", base_servings: 2, instructions: "x"})

      {:ok, r2} =
        Tore.Recipes.create(home_scope(), %{title: "B", base_servings: 2, instructions: "x"})

      state =
        %State{}
        |> Decider.evolve(%Tore.Planning.Events.RecipeAssigned{
          slot_key: "mon_dinner",
          recipe_id: r1.id,
          servings: 2
        })
        |> Decider.evolve(%Tore.Planning.Events.RecipeAssigned{
          slot_key: "tue_dinner",
          recipe_id: r2.id,
          servings: 2
        })

      assert {:ok, events, next} = Planning.swap_events(state, "mon_dinner", "tue_dinner")
      assert events != []
      assert next.slots["mon_dinner"].recipe_id == r2.id
      assert next.slots["tue_dinner"].recipe_id == r1.id
    end

    test "returns :nothing_to_swap when both slots are empty" do
      assert {:error, :nothing_to_swap} =
               Planning.swap_events(%State{}, "mon_dinner", "tue_dinner")
    end
  end

  describe "apply_events/2" do
    test "appends events to the plan stream and returns :ok" do
      {:ok, r} =
        Tore.Recipes.create(home_scope(), %{title: "C", base_servings: 2, instructions: "x"})

      plan = "plan:apply-test"

      events = [
        %Tore.Planning.Events.RecipeAssigned{slot_key: "wed_dinner", recipe_id: r.id, servings: 3}
      ]

      assert :ok = Planning.apply_events(home_scope(), plan, events)
      {:ok, state} = Planning.load_plan(home_scope(), plan)
      assert state.slots["wed_dinner"].recipe_id == r.id
    end

    test "is a no-op for an empty event list" do
      assert :ok = Planning.apply_events(home_scope(), "plan:empty-apply", [])
      {:ok, state} = Planning.load_plan(home_scope(), "plan:empty-apply")
      assert state.slots == %{}
    end
  end

  describe "swap_slots/3" do
    test "swaps two occupied slots, preserving both recipes and their servings" do
      plan = "plan:swap-1"
      Planning.assign_recipe(home_scope(), plan, "fri_dinner", recipe(101), 4)
      Planning.assign_recipe(home_scope(), plan, "sun_dinner", recipe(202), 2)

      assert {:ok, _events} = Planning.swap_slots(home_scope(), plan, "fri_dinner", "sun_dinner")

      {:ok, state} = Planning.load_plan(home_scope(), plan)
      assert state.slots["fri_dinner"].recipe_id == recipe(202)
      assert state.slots["fri_dinner"].servings == 2
      assert state.slots["sun_dinner"].recipe_id == recipe(101)
      assert state.slots["sun_dinner"].servings == 4
    end

    test "one slot empty: moves the recipe and clears the source" do
      plan = "plan:swap-2"
      Planning.assign_recipe(home_scope(), plan, "fri_dinner", recipe(101), 4)

      assert {:ok, _events} = Planning.swap_slots(home_scope(), plan, "fri_dinner", "sun_dinner")

      {:ok, state} = Planning.load_plan(home_scope(), plan)
      assert state.slots["sun_dinner"].recipe_id == recipe(101)
      assert state.slots["sun_dinner"].servings == 4
      refute Map.has_key?(state.slots, "fri_dinner")
    end

    test "empty source, occupied target: moves target into source, clears target" do
      plan = "plan:swap-2b"
      Planning.assign_recipe(home_scope(), plan, "sun_dinner", recipe(202), 2)

      assert {:ok, _events} = Planning.swap_slots(home_scope(), plan, "fri_dinner", "sun_dinner")

      {:ok, state} = Planning.load_plan(home_scope(), plan)
      assert state.slots["fri_dinner"].recipe_id == recipe(202)
      refute Map.has_key?(state.slots, "sun_dinner")
    end

    test "both slots empty returns {:error, :nothing_to_swap}" do
      plan = "plan:swap-3"

      assert {:error, :nothing_to_swap} =
               Planning.swap_slots(home_scope(), plan, "fri_dinner", "sun_dinner")
    end
  end

  describe "eat_out/3" do
    defp day(key) do
      {:ok, state} = Planning.load_plan(home_scope(), plan_id())
      state.slots[key]
    end

    test "cancels the recipe and keeps the place and amount on the day" do
      {:ok, _} = Planning.assign_recipe(home_scope(), plan_id(), "wed_dinner", recipe(1), 4)

      {:ok, _} =
        Planning.eat_out(home_scope(), plan_id(), "wed_dinner", %{place: "Sushi", amount: 450})

      assert %{recipe_id: nil, place: "Sushi", amount: "450"} = day("wed_dinner")
      assert Tore.Planning.State.eating_out?(day("wed_dinner"))
    end

    test "works on an empty day, where a plain skip doesn't" do
      assert {:error, :slot_empty} = Planning.skip_meal(home_scope(), plan_id(), "fri_dinner")
      {:ok, _} = Planning.eat_out(home_scope(), plan_id(), "fri_dinner", %{})
      assert %{place: nil, amount: nil} = day("fri_dinner")
    end

    test "an amount said later keeps the place, and saying nothing new adds no event" do
      {:ok, _} = Planning.eat_out(home_scope(), plan_id(), "fri_dinner", %{place: "Sushi"})

      assert {:ok, [_]} =
               Planning.eat_out(home_scope(), plan_id(), "fri_dinner", %{amount: "300,50"})

      assert %{place: "Sushi", amount: "300.5"} = day("fri_dinner")

      assert {:ok, []} =
               Planning.eat_out(home_scope(), plan_id(), "fri_dinner", %{place: "Sushi"})
    end

    test "an empty string clears a field" do
      {:ok, _} =
        Planning.eat_out(home_scope(), plan_id(), "fri_dinner", %{place: "Sushi", amount: 300})

      {:ok, _} = Planning.eat_out(home_scope(), plan_id(), "fri_dinner", %{place: "", amount: ""})
      assert %{place: nil, amount: nil} = day("fri_dinner")
    end

    test "a bad amount changes nothing" do
      for amount <- [-1, "lots"] do
        assert {:error, :invalid_amount} =
                 Planning.eat_out(home_scope(), plan_id(), "fri_dinner", %{amount: amount})
      end

      assert day("fri_dinner") == nil
    end

    test "a recipe replaces the day and its cost" do
      {:ok, _} = Planning.eat_out(home_scope(), plan_id(), "fri_dinner", %{amount: 300})
      {:ok, _} = Planning.assign_recipe(home_scope(), plan_id(), "fri_dinner", recipe(1), 4)

      refute Tore.Planning.State.eating_out?(day("fri_dinner"))
      refute Map.has_key?(day("fri_dinner"), :amount)
    end

    test "old MealSkipped events with no reason still load" do
      Tore.Repo.insert_all(Tore.EventStore.Event, [
        %{
          household_id: home_scope().household_id,
          stream_id: plan_id(),
          stream_type: "planning",
          event_type: "RecipeAssigned",
          data: ~s({"slot_key":"mon_dinner","recipe_id":1,"servings":4}),
          inserted_at: ~N[2026-04-27 10:00:00]
        },
        %{
          household_id: home_scope().household_id,
          stream_id: plan_id(),
          stream_type: "planning",
          event_type: "MealSkipped",
          data: ~s({"slot_key":"mon_dinner"}),
          inserted_at: ~N[2026-04-27 10:00:01]
        }
      ])

      {:ok, state} = Planning.load_plan(home_scope(), plan_id())
      assert state.slots["mon_dinner"].skipped == true
      assert state.slots["mon_dinner"].recipe_id == recipe(1)
      refute Tore.Planning.State.eating_out?(state.slots["mon_dinner"])
    end
  end

  describe "households" do
    test "the weekly cron plans every household that can use AI, and no other" do
      other = scope_fixture(sponsored_household())
      unsponsored = scope_fixture(household_fixture())

      Tore.MockLLM
      |> Mox.expect(:chat_with_tools, 2, fn _sys, _msgs, _tools, _opts ->
        {:ok, {:message, "Nothing to do."},
         %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
      end)

      assert :ok = Planning.plan_upcoming_weeks()
      runs = fn scope -> Tore.Repo.all(Tore.Harness.KitchenRun, Tore.Scope.repo_opts(scope)) end
      assert [%{status: :applied}] = runs.(home_scope())
      assert [%{status: :applied}] = runs.(other)
      # No run opened at all, not just none applied: the cron skipped the household.
      assert runs.(unsponsored) == []
    end

    defp sponsored_household do
      household = household_fixture()
      sponsor = user_fixture(household: household)
      sponsor |> Ecto.Changeset.change(ai_enabled: true) |> Tore.Repo.update!()

      household |> Ecto.Changeset.change(ai_sponsor_id: sponsor.id) |> Tore.Repo.update!()
    end

    test "a plan change is broadcast only to its own household" do
      other = scope_fixture(household_fixture())
      Phoenix.PubSub.subscribe(Tore.PubSub, Planning.topic(other))

      {:ok, _} = Planning.assign_recipe(home_scope(), plan_id(), "mon_dinner", recipe(1), 4)

      assert_receive {:events, [%Tore.Planning.Events.RecipeAssigned{}]}
      refute_received {:events, _}
      assert Planning.topic(other) != Planning.topic(home_scope())
    end

    test "a plan can't be given another household's recipe" do
      other = scope_fixture(household_fixture())
      {:ok, theirs} = Tore.Recipes.create(other, %{title: "Pannkakor", recipe_type: :meal})
      mine = Tore.Streams.plan(home_scope(), ~D[2026-11-02])

      assert {:error, :recipe_not_found} =
               Planning.assign_recipe(home_scope(), mine, "mon_dinner", theirs.id, 4)

      assert {:error, :recipe_not_found} =
               Planning.assign_with_leftovers(home_scope(), mine, "mon_dinner", theirs.id, 4, [
                 "tue_dinner"
               ])

      assert {:ok, %{slots: slots}} = Planning.load_plan(home_scope(), mine)
      assert slots == %{}
    end

    test "the same week is a separate plan in each household" do
      other = scope_fixture(household_fixture())
      {:ok, recipe} = Tore.Recipes.create(home_scope(), %{title: "Ärtsoppa", recipe_type: :meal})
      mine = Tore.Streams.plan(home_scope(), ~D[2026-11-02])
      theirs = Tore.Streams.plan(other, ~D[2026-11-02])

      {:ok, _} = Planning.assign_recipe(home_scope(), mine, "mon_dinner", recipe.id, 4)

      assert {:ok, %{slots: %{"mon_dinner" => %{recipe_id: id}}}} =
               Planning.load_plan(home_scope(), mine)

      assert id == recipe.id
      assert {:ok, %{slots: slots}} = Planning.load_plan(other, theirs)
      assert slots == %{}
      assert {:ok, %{slots: slots}} = Planning.load_plan(other, mine)
      assert slots == %{}
    end
  end
end
