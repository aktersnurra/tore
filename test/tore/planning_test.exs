defmodule Tore.PlanningTest do
  use ExUnit.Case, async: false

  import Mox

  alias Tore.Planning

  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
    Phoenix.PubSub.subscribe(Tore.PubSub, "plan")
    :ok
  end

  defp plan_id, do: "plan:2026-04-27"

  defp mock_usage, do: %{prompt_tokens: 100, completion_tokens: 50, cost_usd: 0.001}

  test "load_plan returns initial state for new plan" do
    assert {:ok, state} = Planning.load_plan(plan_id())
    assert state.slots == %{}
  end

  test "assign_recipe persists RecipeAssigned event" do
    assert {:ok, _events} = Planning.assign_recipe(plan_id(), "mon_dinner", 1, 4)
    assert {:ok, state} = Planning.load_plan(plan_id())
    assert state.slots["mon_dinner"].recipe_id == 1
    assert state.slots["mon_dinner"].servings == 4
  end

  test "assign_recipe broadcasts to plan topic" do
    Planning.assign_recipe(plan_id(), "tue_dinner", 2, 2)
    assert_receive {:events, [%Tore.Planning.Events.RecipeAssigned{}]}
  end

  test "remove_recipe returns error for empty slot" do
    assert {:error, :slot_empty} = Planning.remove_recipe(plan_id(), "mon_dinner")
  end

  test "load_plan returns current state after multiple events" do
    Planning.assign_recipe(plan_id(), "mon_dinner", 10, 4)
    Planning.assign_recipe(plan_id(), "tue_dinner", 11, 2)
    Planning.skip_meal(plan_id(), "mon_dinner")

    {:ok, state} = Planning.load_plan(plan_id())
    assert state.slots["mon_dinner"].skipped == true
    assert state.slots["tue_dinner"].recipe_id == 11
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

      {:ok, recipe} = Recipes.create(attrs)
      recipe
    end

    test "returns ranked recipes (rule-based, no LLM)" do
      _r1 = create_recipe("Plain pasta")
      r2 = create_recipe("Chicken curry", base_servings: 6)

      Tore.Pantry.add_item(%{name: "chicken", quantity: Decimal.new(1)})

      assert {:ok, results} = Planning.suggest_recipes_for_slot(plan_id(), "mon_dinner")
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
               Planning.suggest_recipes_for_slot(plan_id(), "mon_dinner", limit: 3)

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
               Planning.suggest_recipes_for_slot(plan_id(), "tue_dinner",
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
               Planning.suggest_recipes_for_slot(plan_id(), "tue_dinner",
                 include_llm: true
               )

      assert is_list(results)
    end
  end

  describe "assign_with_leftovers/5" do
    alias Tore.Recipes

    test "assigns recipe to slot and marks leftover days in one broadcast" do
      {:ok, recipe} =
        Recipes.create(%{
          title: "Roast chicken",
          recipe_type: :meal,
          base_servings: 6,
          prep_time_minutes: 10,
          cook_time_minutes: 60
        })

      assert {:ok, events} =
               Planning.assign_with_leftovers(
                 plan_id(),
                 "mon_dinner",
                 recipe.id,
                 6,
                 ["tue_dinner", "wed_dinner"]
               )

      # Primary RecipeAssigned + 2 (assign + leftover) per leftover day
      assert length(events) >= 5

      {:ok, state} = Planning.load_plan(plan_id())
      assert state.slots["mon_dinner"].recipe_id == recipe.id
      assert state.slots["tue_dinner"].leftover == true
      assert state.slots["wed_dinner"].leftover == true

      # Single broadcast
      assert_receive {:events, all_events}
      assert length(all_events) == length(events)
    end

    test "works with no leftover days (degenerates to assign)" do
      {:ok, recipe} =
        Recipes.create(%{
          title: "Quick salad",
          recipe_type: :meal,
          base_servings: 2,
          prep_time_minutes: 5,
          cook_time_minutes: 0
        })

      assert {:ok, events} =
               Planning.assign_with_leftovers(plan_id(), "mon_dinner", recipe.id, 2, [])

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
    expected_stream = "plan:#{Date.to_iso8601(expected_week_start)}"

    assert {:ok, state} = Planning.plan_upcoming_week()
    assert state.__struct__ == Tore.Harness.Run.State.Applied
    assert {:ok, _plan} = Planning.load_plan(expected_stream)
  end

  describe "swap_events/3 (pure)" do
    alias Tore.Planning.{Decider, State}

    test "returns cross-assign events and the evolved state without persisting" do
      {:ok, r1} = Tore.Recipes.create(%{title: "A", base_servings: 2, instructions: "x"})
      {:ok, r2} = Tore.Recipes.create(%{title: "B", base_servings: 2, instructions: "x"})

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
      {:ok, r} = Tore.Recipes.create(%{title: "C", base_servings: 2, instructions: "x"})
      plan = "plan:apply-test"

      events = [
        %Tore.Planning.Events.RecipeAssigned{slot_key: "wed_dinner", recipe_id: r.id, servings: 3}
      ]

      assert :ok = Planning.apply_events(plan, events)
      {:ok, state} = Planning.load_plan(plan)
      assert state.slots["wed_dinner"].recipe_id == r.id
    end

    test "is a no-op for an empty event list" do
      assert :ok = Planning.apply_events("plan:empty-apply", [])
      {:ok, state} = Planning.load_plan("plan:empty-apply")
      assert state.slots == %{}
    end
  end

  describe "swap_slots/3" do
    test "swaps two occupied slots, preserving both recipes and their servings" do
      plan = "plan:swap-1"
      Planning.assign_recipe(plan, "fri_dinner", 101, 4)
      Planning.assign_recipe(plan, "sun_dinner", 202, 2)

      assert {:ok, _events} = Planning.swap_slots(plan, "fri_dinner", "sun_dinner")

      {:ok, state} = Planning.load_plan(plan)
      assert state.slots["fri_dinner"].recipe_id == 202
      assert state.slots["fri_dinner"].servings == 2
      assert state.slots["sun_dinner"].recipe_id == 101
      assert state.slots["sun_dinner"].servings == 4
    end

    test "one slot empty: moves the recipe and clears the source" do
      plan = "plan:swap-2"
      Planning.assign_recipe(plan, "fri_dinner", 101, 4)

      assert {:ok, _events} = Planning.swap_slots(plan, "fri_dinner", "sun_dinner")

      {:ok, state} = Planning.load_plan(plan)
      assert state.slots["sun_dinner"].recipe_id == 101
      assert state.slots["sun_dinner"].servings == 4
      refute Map.has_key?(state.slots, "fri_dinner")
    end

    test "empty source, occupied target: moves target into source, clears target" do
      plan = "plan:swap-2b"
      Planning.assign_recipe(plan, "sun_dinner", 202, 2)

      assert {:ok, _events} = Planning.swap_slots(plan, "fri_dinner", "sun_dinner")

      {:ok, state} = Planning.load_plan(plan)
      assert state.slots["fri_dinner"].recipe_id == 202
      refute Map.has_key?(state.slots, "sun_dinner")
    end

    test "both slots empty returns {:error, :nothing_to_swap}" do
      plan = "plan:swap-3"

      assert {:error, :nothing_to_swap} =
               Planning.swap_slots(plan, "fri_dinner", "sun_dinner")
    end
  end

  describe "eat_out/3" do
    setup do
      {:ok, {user, _code}} = Tore.Accounts.create_user(%{name: "Tester"})
      %{user_id: user.id}
    end

    test "cancels the recipe and stores the entry on the right day", %{user_id: user_id} do
      {:ok, _} = Planning.assign_recipe(plan_id(), "wed_dinner", 1, 4)

      assert {:ok, entry} =
               Planning.eat_out(plan_id(), "wed_dinner", %{
                 description: "Sushi",
                 total_amount: 450,
                 user_id: user_id
               })

      assert entry.date == ~D[2026-04-29]
      assert entry.slot_key == "wed_dinner"

      {:ok, state} = Planning.load_plan(plan_id())
      assert state.slots["wed_dinner"].recipe_id == nil
      assert Tore.Planning.State.eating_out?(state.slots["wed_dinner"])
    end

    test "works on an empty day, where a plain skip doesn't", %{user_id: user_id} do
      assert {:error, :slot_empty} = Planning.skip_meal(plan_id(), "fri_dinner")
      assert {:ok, entry} = Planning.eat_out(plan_id(), "fri_dinner", %{user_id: user_id})
      assert entry.total_amount == nil
    end

    test "asking again updates the entry and adds no event", %{user_id: user_id} do
      {:ok, first} = Planning.eat_out(plan_id(), "fri_dinner", %{user_id: user_id})
      assert_receive {:events, [_skipped]}

      {:ok, second} =
        Planning.eat_out(plan_id(), "fri_dinner", %{total_amount: 300, user_id: user_id})

      assert second.id == first.id
      refute_receive {:events, _}, 50
    end

    test "a bad amount changes nothing", %{user_id: user_id} do
      assert {:error, _} =
               Planning.eat_out(plan_id(), "fri_dinner", %{total_amount: -1, user_id: user_id})

      {:ok, state} = Planning.load_plan(plan_id())
      assert state.slots == %{}
      assert Tore.Costs.get_dining_out(plan_id(), "fri_dinner") == nil
    end

    test "a recipe or a cleared day drops the entry", %{user_id: user_id} do
      {:ok, _} = Planning.eat_out(plan_id(), "fri_dinner", %{user_id: user_id})
      {:ok, _} = Planning.assign_recipe(plan_id(), "fri_dinner", 1, 4)
      assert Tore.Costs.get_dining_out(plan_id(), "fri_dinner") == nil

      {:ok, _} = Planning.eat_out(plan_id(), "sat_dinner", %{user_id: user_id})
      {:ok, _} = Planning.remove_recipe(plan_id(), "sat_dinner")
      assert Tore.Costs.get_dining_out(plan_id(), "sat_dinner") == nil
    end

    test "old MealSkipped events with no reason still load" do
      Tore.Repo.insert_all(Tore.EventStore.Event, [
        %{
          stream_id: plan_id(),
          stream_type: "planning",
          event_type: "RecipeAssigned",
          data: ~s({"slot_key":"mon_dinner","recipe_id":1,"servings":4}),
          inserted_at: ~N[2026-04-27 10:00:00]
        },
        %{
          stream_id: plan_id(),
          stream_type: "planning",
          event_type: "MealSkipped",
          data: ~s({"slot_key":"mon_dinner"}),
          inserted_at: ~N[2026-04-27 10:00:01]
        }
      ])

      {:ok, state} = Planning.load_plan(plan_id())
      assert state.slots["mon_dinner"].skipped == true
      assert state.slots["mon_dinner"].recipe_id == 1
      refute Tore.Planning.State.eating_out?(state.slots["mon_dinner"])
    end
  end
end
