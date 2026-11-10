defmodule Tore.Harness.Kinds.PlannerTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Planning, Recipes}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.{PlanDiff, RecipeProposal}
  alias Tore.Harness.Kinds.{PlannerCommand, SetPlanSlot, WeeklyPlanning}
  alias Tore.Planning.{Commands, Decider, State}

  setup :verify_on_exit!

  @week ~D[2026-06-08]
  @usage %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}

  setup do
    stub(Tore.MockHTTP, :fetch, fn _url -> {:error, :not_found} end)
    # A confirmed recipe's picture is made after commit; these tests don't look at it.
    stub(Tore.MockLLM, :text, fn _, _, _ -> {:error, :ai_unavailable} end)
    plan = Tore.Streams.plan(home_scope(), @week)
    {:ok, recipe} = Recipes.create(home_scope(), recipe("Stew"))
    {:ok, _} = Planning.assign_recipe(home_scope(), plan, "mon_dinner", recipe.id, 4)
    %{plan: plan, recipe: recipe}
  end

  # :image_url keeps Recipes.create's image task off MockLLM.
  defp recipe(title),
    do: %{
      title: title,
      recipe_type: :meal,
      base_servings: 4,
      image_url: "https://example.com/x.jpg"
    }

  defp command(plan, text), do: %{command: text, plan_stream_id: plan, week_start: @week}

  defp tool_call(name, args) do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: name, args: args}]}, @usage}
    end)
  end

  defp done,
    do:
      expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
        {:ok, {:message, "Done."}, @usage}
      end)

  defp slots(plan) do
    {:ok, state} = Planning.load_plan(home_scope(), plan)
    {state.slots, state.pins}
  end

  describe "a planner command" do
    test "applies the planner's change, undoes it to what was there, and the run reads back equal",
         %{plan: plan} do
      before = slots(plan)
      tool_call("skip_meal", %{"slot_key" => "mon_dinner", "rationale" => "busy"})
      done()

      assert {:ok, %KitchenRun{status: :applied, kind: "planner_command_run"} = run} =
               Runs.start(home_scope(), PlannerCommand, command(plan, "skip monday"))

      assert run == Runs.get(home_scope(), run.id)

      assert [%PlanDiff{events: [%{event_type: "MealSkipped", rationale: ["busy"]}]}] =
               run.artifacts

      assert {%{"mon_dinner" => %{skipped: true}}, _} = slots(plan)
      assert run.prompt_tokens == 2

      assert {:ok, %KitchenRun{status: :reverted}} = Runs.revert(home_scope(), run.id)
      assert slots(plan) == before
    end

    test "logs each agent step under the run", %{plan: plan} do
      done()
      {:ok, run} = Runs.start(home_scope(), PlannerCommand, command(plan, "hello"))

      assert [_ | _] = rows = Tore.AiOperations.list_for_run(home_scope(), run.id)
      assert Enum.all?(rows, &(&1.run_stream_id == run.id))
    end

    test "a question waits for the person", %{plan: plan} do
      tool_call("ask_user", %{"question" => "which Monday?"})

      assert {:ok, %KitchenRun{status: :needs_user, question: "which Monday?"}} =
               Runs.start(home_scope(), PlannerCommand, command(plan, "skip monday"))
    end

    test "a pinned day fails the run and the plan is untouched", %{plan: plan} do
      {:ok, _} = Planning.pin_slot(home_scope(), plan, "mon_dinner", true)
      before = slots(plan)
      tool_call("skip_meal", %{"slot_key" => "mon_dinner", "rationale" => "out"})
      done()

      assert {:ok,
              %KitchenRun{
                status: :failed,
                failure_code: :slot_pinned,
                repair_action: {:edit_plan, ["mon_dinner"]}
              }} =
               Runs.start(home_scope(), PlannerCommand, command(plan, "skip monday"))

      assert slots(plan) == before
    end

    test "a refused LLM call fails the run and writes nothing", %{plan: plan} do
      before = slots(plan)
      stub(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ -> {:error, :boom} end)

      assert {:error, {:step_failed, :boom}} =
               Runs.start(home_scope(), PlannerCommand, command(plan, "skip monday"))

      assert %KitchenRun{status: :failed, failure_code: :internal_error} =
               Runs.latest_on_surface(home_scope(), :plan)

      assert slots(plan) == before
    end

    test "plan screens hear about it only once it has committed", %{plan: plan} do
      Phoenix.PubSub.subscribe(Tore.PubSub, Planning.topic(home_scope()))
      tool_call("skip_meal", %{"slot_key" => "mon_dinner", "rationale" => "busy"})
      done()

      {:ok, run} = Runs.start(home_scope(), PlannerCommand, command(plan, "skip monday"))
      assert_receive {:events, _}
      {:ok, _} = Runs.revert(home_scope(), run.id)
      assert_receive {:events, _}
    end
  end

  describe "a recipe the planner proposes" do
    setup %{plan: plan} do
      proposal = %RecipeProposal{
        title: "Tofu ramen",
        instructions: "Simmer.",
        base_servings: 4,
        ingredients: [%{name: "tofu", quantity: "300", unit: "g"}],
        tags: [],
        source: :generation,
        pending_assignment: %{slot_key: "tue_dinner", servings: 2}
      }

      {:ok, run} =
        Runs.submit(home_scope(), PlannerCommand, proposal, command(plan, "ramen tuesday"))

      %{run: run, proposal: proposal}
    end

    test "waits for review, and confirming saves it on the day it was meant for", %{
      run: run,
      plan: plan,
      proposal: proposal
    } do
      assert %KitchenRun{status: :needs_user, artifacts: [%RecipeProposal{}]} = run

      assert {:ok, %KitchenRun{status: :applied} = applied} =
               Runs.confirm(home_scope(), run.id, proposal)

      assert %{title: "Tofu ramen", id: id} =
               Recipes.list(home_scope()) |> Enum.find(&(&1.title == "Tofu ramen"))

      assert {%{"tue_dinner" => %{recipe_id: ^id, servings: 2}}, _} = slots(plan)

      assert {:ok, _} = Runs.revert(home_scope(), applied.id)
      refute Recipes.get(home_scope(), id)
      assert {slots, _} = slots(plan)
      refute Map.has_key?(slots, "tue_dinner")
    end

    test "an edited proposal saves the edits, ingredients and all", %{
      run: run,
      proposal: proposal
    } do
      edited = %{
        proposal
        | title: "Vegan ramen",
          ingredients: proposal.ingredients ++ [%{name: "miso", quantity: "2", unit: "msk"}]
      }

      {:ok, _} = Runs.confirm(home_scope(), run.id, edited)

      %{id: id} = Enum.find(Recipes.list(home_scope()), &(&1.title == "Vegan ramen"))
      assert length(Recipes.get!(home_scope(), id).recipe_ingredients) == 2
    end

    test "an edit the verifier refuses saves nothing, and the recipe still waits", %{
      run: run,
      proposal: proposal
    } do
      assert {:error, {:verifier_failed, :no_ingredients, :reject}} =
               Runs.confirm(home_scope(), run.id, %{proposal | ingredients: []})

      assert %KitchenRun{status: :needs_user} = Runs.get(home_scope(), run.id)
      refute Enum.any?(Recipes.list(home_scope()), &(&1.title == "Tofu ramen"))
    end

    test "discarding saves nothing and leaves the day", %{run: run, plan: plan} do
      assert {:ok, %KitchenRun{status: :discarded}} =
               Runs.discard(home_scope(), run.id, :user_discarded)

      refute Enum.any?(Recipes.list(home_scope()), &(&1.title == "Tofu ramen"))
      assert {slots, _} = slots(plan)
      refute Map.has_key?(slots, "tue_dinner")
    end

    test "can be confirmed once", %{run: run, proposal: proposal} do
      {:ok, _} = Runs.confirm(home_scope(), run.id, proposal)

      assert {:error, {:invalid_transition, :applied, :confirm}} =
               Runs.confirm(home_scope(), run.id, proposal)
    end

    test "is saved as made by whoever confirms it", %{run: run, proposal: proposal} do
      person = scope_fixture(user_fixture())
      {:ok, _} = Runs.confirm(person, run.id, proposal)

      assert %{created_by: by} =
               Enum.find(Recipes.list(home_scope()), &(&1.title == "Tofu ramen"))

      assert by == person.user_id
    end

    test "undo still works after the recipe was deleted by hand", %{run: run, proposal: proposal} do
      {:ok, applied} = Runs.confirm(home_scope(), run.id, proposal)
      recipe = Enum.find(Recipes.list(home_scope()), &(&1.title == "Tofu ramen"))
      {:ok, _} = Recipes.delete(home_scope(), recipe)

      assert {:ok, %KitchenRun{status: :reverted}} = Runs.revert(home_scope(), applied.id)
    end

    test "a day pinned while it waited is left alone, and nothing is saved", %{
      run: run,
      plan: plan,
      proposal: proposal
    } do
      {:ok, _} = Planning.pin_slot(home_scope(), plan, "tue_dinner", true)

      assert {:error, {:verifier_failed, :slot_pinned, {:edit_plan, ["tue_dinner"]}}} =
               Runs.confirm(home_scope(), run.id, proposal)

      assert %KitchenRun{status: :needs_user} = Runs.get(home_scope(), run.id)
      refute Enum.any?(Recipes.list(home_scope()), &(&1.title == "Tofu ramen"))
    end

    test "a day marked eating out while it waited is left alone", %{
      run: run,
      plan: plan,
      proposal: proposal
    } do
      {:ok, _} = Planning.eat_out(home_scope(), plan, "tue_dinner", %{})

      assert {:error, {:verifier_failed, :slot_eating_out, _}} =
               Runs.confirm(home_scope(), run.id, proposal)

      assert {%{"tue_dinner" => slot}, _} = slots(plan)
      assert State.eating_out?(slot)
    end
  end

  describe "Capture putting a recipe on a day" do
    test "applies, and undo restores the recipe that was there", %{plan: plan, recipe: stew} do
      {:ok, soup} = Recipes.create(home_scope(), recipe("Soup"))
      monday = @week
      {:ok, diff, ctx} = SetPlanSlot.proposal(home_scope(), monday, soup.id, 4)

      assert {:ok, %KitchenRun{status: :applied} = run} =
               Runs.submit(home_scope(), SetPlanSlot, diff, ctx)

      assert {%{"mon_dinner" => %{recipe_id: id}}, _} = slots(plan)
      assert id == soup.id

      {:ok, _} = Runs.revert(home_scope(), run.id)
      assert {%{"mon_dinner" => %{recipe_id: id}}, _} = slots(plan)
      assert id == stew.id
    end

    test "leaves a pinned day as it is", %{plan: plan} do
      {:ok, _} = Planning.pin_slot(home_scope(), plan, "mon_dinner", true)
      {:ok, soup} = Recipes.create(home_scope(), recipe("Soup"))
      {:ok, diff, ctx} = SetPlanSlot.proposal(home_scope(), @week, soup.id, 4)

      assert {:ok, %KitchenRun{status: :failed, failure_code: :slot_pinned}} =
               Runs.submit(home_scope(), SetPlanSlot, diff, ctx)
    end

    test "undo puts the day back as it was, even over a later eat-out", %{plan: plan} do
      {:ok, soup} = Recipes.create(home_scope(), recipe("Soup"))
      {:ok, diff, ctx} = SetPlanSlot.proposal(home_scope(), ~D[2026-06-12], soup.id, 4)
      {:ok, run} = Runs.submit(home_scope(), SetPlanSlot, diff, ctx)
      {:ok, _} = Planning.eat_out(home_scope(), plan, "fri_dinner", %{amount: 600})

      {:ok, _} = Runs.revert(home_scope(), run.id)

      assert {slots, _} = slots(plan)
      refute Map.has_key?(slots, "fri_dinner")
    end

    test "refuses a recipe the household doesn't have" do
      assert {:error, :recipe_not_found} = SetPlanSlot.proposal(home_scope(), @week, -1, 4)
    end
  end

  test "the weekly planner fills the week as the system", %{plan: plan, recipe: stew} do
    tool_call("assign_recipe", %{
      "slot_key" => "wed_dinner",
      "recipe_id" => stew.id,
      "servings" => 4,
      "rationale" => "fits"
    })

    done()

    assert {:ok, %KitchenRun{status: :applied, actor: :system, kind: "weekly_planning_run"}} =
             Runs.start(home_scope(), WeeklyPlanning, %{plan_stream_id: plan, week_start: @week})
  end

  test "restoring slots puts back exactly what was there, over generated plans" do
    :rand.seed(:exsss, {7, 8, 9})
    keys = ~w(mon_dinner tue_dinner wed_dinner thu_dinner)

    for _ <- 1..200 do
      start = generate(%State{}, keys, 6)
      touched = Enum.take_random(keys, Enum.random(1..4))
      before = Planning.slots_before(start, touched)
      changed = generate(start, touched, 5)

      restored =
        Enum.reduce(Planning.restore_events(changed, before), changed, &Decider.evolve(&2, &1))

      assert Planning.slots_before(restored, touched) == before
    end
  end

  # Random valid planning commands over `keys`, as the decider would allow them.
  defp generate(state, keys, n) do
    Enum.reduce(1..n, state, fn _, acc ->
      key = Enum.random(keys)

      command =
        Enum.random([
          %Commands.AssignRecipe{
            slot_key: key,
            recipe_id: Enum.random(1..3),
            servings: Enum.random(1..6)
          },
          %Commands.RemoveRecipe{slot_key: key},
          %Commands.SkipMeal{slot_key: key},
          %Commands.EatOut{
            slot_key: key,
            place: Enum.random([nil, "", "Sushi"]),
            amount: Enum.random([nil, "", 100, "250.5"])
          },
          %Commands.MarkLeftover{slot_key: key},
          %Commands.PinSlot{slot_key: key, pin: true},
          %Commands.UnpinSlot{slot_key: key}
        ])

      case Decider.decide(command, acc) do
        {:ok, events} -> Enum.reduce(events, acc, &Decider.evolve(&2, &1))
        {:error, _} -> acc
      end
    end)
  end
end
