defmodule Tore.Harness.Kinds.PlannerAgentTest do
  @moduledoc "The plan kinds driven through the real agent loop and its tools."
  use Tore.DataCase, async: false
  import Mox

  alias Tore.{Planning, Recipes}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Kinds.{PlannerCommand, WeeklyPlanning}

  setup :verify_on_exit!

  @week ~D[2026-08-17]
  @usage %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}

  setup do
    # :image_url sends Recipes.create's picture task to the HTTP stub, not MockLLM.
    stub(Tore.MockHTTP, :fetch, fn _url -> {:error, :not_found} end)
    %{plan: Tore.Streams.plan(home_scope(), @week)}
  end

  defp command(plan, text), do: %{command: text, plan_stream_id: plan, week_start: @week}

  defp recipe(attrs),
    do:
      Recipes.create(
        home_scope(),
        Map.merge(%{base_servings: 4, image_url: "https://example.com/x.jpg"}, attrs)
      )

  # The ref resolve_recipe returned, from the tool message the agent sends back.
  defp resolved_ref(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      if (msg[:role] || msg["role"]) == "tool",
        do:
          msg |> Map.get(:content, msg["content"]) |> Jason.decode!() |> get_in(["match", "ref"])
    end)
  end

  defp resolve_then(query, next) do
    Tore.MockLLM
    |> expect(:chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "resolve_recipe", args: %{"query" => query}}]},
       @usage}
    end)
    |> expect(:chat_with_tools, fn _, msgs, _, _ ->
      {:ok,
       {:tool_calls,
        [%{id: "c2", name: elem(next, 0), args: elem(next, 1).(resolved_ref(msgs))}]}, @usage}
    end)
  end

  test "the system prompt carries the household and the week", %{plan: plan} do
    {:ok, _} =
      Tore.Household.update_preferences(home_scope(), %{dietary_restrictions: ["vegetarian"]})

    test_pid = self()

    expect(Tore.MockLLM, :chat_with_tools, fn sys, _, _, _ ->
      send(test_pid, {:system_prompt, sys})
      {:ok, {:message, "Done."}, @usage}
    end)

    {:ok, _} = Runs.start(home_scope(), PlannerCommand, command(plan, "what's for dinner"))

    assert_receive {:system_prompt, sys}
    assert sys =~ "You are the planner agent for Tore"
    assert sys =~ "Household preferences:"
    assert sys =~ "This week's dinner plan:"
    # Capture's prompt, not the planner's.
    refute sys =~ "friendly and practical AI cooking and meal planning assistant"
  end

  test "the weekly planner fills dinners: it sees a lunch and is told to leave lunches be", %{
    plan: plan
  } do
    {:ok, soup} = recipe(%{title: "Ärtsoppa"})
    {:ok, _} = Planning.assign_recipe(home_scope(), plan, "sat_lunch", soup.id, 4)
    test_pid = self()

    expect(Tore.MockLLM, :chat_with_tools, fn sys, msgs, _, _ ->
      send(test_pid, {:prompt, sys <> Enum.map_join(msgs, "\n", &inspect/1)})
      {:ok, {:message, "Done."}, @usage}
    end)

    Runs.start(home_scope(), WeeklyPlanning, %{plan_stream_id: plan, week_start: @week})

    assert_receive {:prompt, prompt}
    assert prompt =~ "Saturday 2026-08-22 (sat_dinner): empty; lunch (sat_lunch): Ärtsoppa"
    assert prompt =~ "Plan no lunches"

    {:ok, state} = Planning.load_plan(home_scope(), plan)
    assert Map.keys(state.slots) == ["sat_lunch"]
  end

  describe "a variant the agent generates" do
    setup do
      {:ok, ramen} =
        recipe(%{
          title: "Miso Ramen",
          instructions: "Simmer the broth.",
          ingredients: [%{name: "pork belly", quantity: Decimal.new("300"), unit: "g"}]
        })

      %{ramen: ramen}
    end

    defp variant(ramen, args, payload) do
      resolve_then(ramen.title, {"generate_recipe_variant", &Map.put(args, "recipe_ref", &1)})
      expect(Tore.MockLLM, :text, fn _, _, _ -> {:ok, payload, @usage} end)
    end

    test "is saved on the day it was meant for", %{plan: plan, ramen: ramen} do
      variant(
        ramen,
        %{"instruction" => "make it vegetarian", "slot_key" => "mon_dinner", "servings" => 4},
        %{
          "title" => "Vegetarian Miso Ramen",
          "base_servings" => 4,
          "ingredients" => [%{"item" => "firm tofu", "quantity" => 300, "unit" => "g"}],
          "steps" => [
            %{"order" => 1, "phase" => "COOKING", "action" => "Simmer.", "ingredients" => []}
          ],
          "tags" => ["vegetarian"]
        }
      )

      assert {:ok, %KitchenRun{status: :applied, artifacts: [%RecipeProposal{} = proposal]}} =
               Runs.start(home_scope(), PlannerCommand, command(plan, "vegetarian ramen"))

      assert proposal.title == "Vegetarian Miso Ramen"
      assert proposal.source == :generation
      assert proposal.pending_assignment == %{slot_key: "mon_dinner", servings: 4}
    end

    test "with no ingredients fails, and nothing waits", %{plan: plan, ramen: ramen} do
      variant(ramen, %{"instruction" => "simpler"}, %{
        "title" => "Empty Ramen",
        "base_servings" => 4,
        "ingredients" => [],
        "steps" => []
      })

      assert {:ok, %KitchenRun{status: :failed, failure_code: :no_ingredients}} =
               Runs.start(home_scope(), PlannerCommand, command(plan, "simpler ramen"))
    end
  end

  test "the weekly planner fills an empty day and leaves pinned and planned days", %{plan: plan} do
    {:ok, stew} = recipe(%{title: "Lentil stew", recipe_type: :meal})
    {:ok, pasta} = recipe(%{title: "Pinned pasta", recipe_type: :meal})
    {:ok, _} = Planning.assign_recipe(home_scope(), plan, "mon_dinner", pasta.id, 4)
    {:ok, _} = Planning.pin_slot(home_scope(), plan, "mon_dinner", true)
    {:ok, _} = Planning.assign_recipe(home_scope(), plan, "tue_dinner", stew.id, 4)

    resolve_then(
      "Lentil stew",
      {"assign_recipe",
       &%{"slot_key" => "wed_dinner", "recipe_ref" => &1, "servings" => 4, "rationale" => "empty"}}
    )

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "Filled."}, @usage}
    end)

    assert {:ok, %KitchenRun{status: :applied}} =
             Runs.start(home_scope(), WeeklyPlanning, %{plan_stream_id: plan, week_start: @week})

    {:ok, state} = Planning.load_plan(home_scope(), plan)
    assert state.slots["wed_dinner"].recipe_id == stew.id
    assert state.slots["mon_dinner"].recipe_id == pasta.id
    assert Map.has_key?(state.pins, "mon_dinner")
    assert state.slots["tue_dinner"].recipe_id == stew.id
  end

  describe "a budget" do
    setup do
      {:ok, steak} =
        recipe(%{title: "Oxfilé", ingredients: [%{name: "oxfilé", quantity: 1, unit: "st"}]})

      {:ok, lentils} =
        recipe(%{title: "Linsgryta", ingredients: [%{name: "linser", quantity: 1, unit: "st"}]})

      for {name, kr} <- [{"oxfilé", "400"}, {"linser", "30"}] do
        Repo.update_all(
          Ecto.Query.from(i in Tore.Recipes.Ingredient, where: i.name == ^name),
          [set: [estimated_price: Decimal.new(kr), estimated_unit: "st"]],
          Tore.Scope.repo_opts(home_scope())
        )
      end

      %{steak: steak, lentils: lentils}
    end

    defp assigns(title, slot \\ "mon_dinner") do
      resolve_then(
        title,
        {"assign_recipe",
         &%{"slot_key" => slot, "recipe_ref" => &1, "servings" => 4, "rationale" => "x"}}
      )

      expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
        {:ok, {:message, "Done."}, @usage}
      end)
    end

    test "over it, the planner tries once more and the cheaper plan is kept", %{
      plan: plan,
      lentils: lentils
    } do
      :ok = Tore.Budget.set_week(home_scope(), @week, Decimal.new("100"))
      test_pid = self()

      assigns("Oxfilé")

      Tore.MockLLM
      |> expect(:chat_with_tools, fn _, [%{content: text}], _, _ ->
        send(test_pid, {:retry, text})

        {:ok,
         {:tool_calls, [%{id: "c1", name: "resolve_recipe", args: %{"query" => "Linsgryta"}}]},
         @usage}
      end)
      |> expect(:chat_with_tools, fn _, msgs, _, _ ->
        args = %{
          "slot_key" => "mon_dinner",
          "recipe_ref" => resolved_ref(msgs),
          "servings" => 4,
          "rationale" => "x"
        }

        {:ok, {:tool_calls, [%{id: "c2", name: "assign_recipe", args: args}]}, @usage}
      end)
      |> expect(:chat_with_tools, fn _, _, _, _ -> {:ok, {:message, "Cheaper."}, @usage} end)

      assert {:ok, %KitchenRun{status: :applied}} =
               Runs.start(home_scope(), WeeklyPlanning, %{plan_stream_id: plan, week_start: @week})

      # The steak, 400 kr, and six open days at a typical dinner, the same.
      assert_received {:retry, text}
      assert text =~ "about 2800 kr, 2700 kr over"

      {:ok, state} = Planning.load_plan(home_scope(), plan)
      assert state.slots["mon_dinner"].recipe_id == lentils.id
    end

    test "within it, the plan is applied as the planner made it", %{plan: plan, steak: steak} do
      :ok = Tore.Budget.set_week(home_scope(), @week, Decimal.new("3000"))
      assigns("Oxfilé")

      assert {:ok, %KitchenRun{status: :applied}} =
               Runs.start(home_scope(), WeeklyPlanning, %{plan_stream_id: plan, week_start: @week})

      {:ok, state} = Planning.load_plan(home_scope(), plan)
      assert state.slots["mon_dinner"].recipe_id == steak.id
    end

    test "a retry may not change a dinner that was there before, however much cheaper", %{
      plan: plan,
      steak: steak,
      lentils: lentils
    } do
      {:ok, _} = Planning.assign_recipe(home_scope(), plan, "mon_dinner", steak.id, 4)
      :ok = Tore.Budget.set_week(home_scope(), @week, Decimal.new("100"))

      # First Tore fills Tuesday; told it's over, it swaps the household's Monday instead.
      assigns("Linsgryta", "tue_dinner")
      assigns("Linsgryta", "mon_dinner")

      assert {:ok, %KitchenRun{status: :applied}} =
               Runs.start(home_scope(), WeeklyPlanning, %{plan_stream_id: plan, week_start: @week})

      {:ok, state} = Planning.load_plan(home_scope(), plan)
      assert state.slots["mon_dinner"].recipe_id == steak.id
      assert state.slots["tue_dinner"].recipe_id == lentils.id
    end

    test "a retry that costs no less leaves the first plan", %{plan: plan, steak: steak} do
      :ok = Tore.Budget.set_week(home_scope(), @week, Decimal.new("100"))
      assigns("Oxfilé")
      assigns("Oxfilé")

      assert {:ok, %KitchenRun{status: :applied}} =
               Runs.start(home_scope(), WeeklyPlanning, %{plan_stream_id: plan, week_start: @week})

      {:ok, state} = Planning.load_plan(home_scope(), plan)
      assert state.slots["mon_dinner"].recipe_id == steak.id
    end
  end
end
