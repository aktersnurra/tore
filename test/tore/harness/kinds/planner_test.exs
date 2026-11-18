defmodule Tore.Harness.Kinds.PlannerTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Planning, Recipes}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.{PlanDiff, RecipeProposal}
  alias Tore.Harness.Kinds.{PlannerCommand, SetPlanSlot}
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

      assert {:ok, %KitchenRun{status: :reverted}} = Runs.revert(home_scope(), run.id)
      assert slots(plan) == before
    end

    test "the prompt names the week's mode once", %{plan: plan} do
      {:ok, _} = Tore.WeekMode.set_mode(home_scope(), "low_effort")
      test_pid = self()

      expect(Tore.MockLLM, :chat_with_tools, fn system, _, _, _ ->
        send(test_pid, {:system, system})
        {:ok, {:message, "Done."}, @usage}
      end)

      {:ok, _run} = Runs.start(home_scope(), PlannerCommand, command(plan, "hello"))

      assert_received {:system, system}
      assert [_before, _after] = String.split(system, "Current week mode: ")
      assert system =~ "Current week mode: Low effort."
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

      %{proposal: proposal, ctx: command(plan, "ramen tuesday")}
    end

    test "is saved straight away on the day it was meant for, and undo deletes it", %{
      plan: plan,
      proposal: proposal,
      ctx: ctx
    } do
      assert {:ok, %KitchenRun{status: :applied} = run} =
               Runs.submit(home_scope(), PlannerCommand, proposal, ctx)

      assert %{title: "Tofu ramen", id: id} =
               Recipes.list(home_scope()) |> Enum.find(&(&1.title == "Tofu ramen"))

      assert {%{"tue_dinner" => %{recipe_id: ^id, servings: 2}}, _} = slots(plan)

      assert {:ok, _} = Runs.revert(home_scope(), run.id)
      refute Recipes.get(home_scope(), id)
      assert {slots, _} = slots(plan)
      refute Map.has_key?(slots, "tue_dinner")
    end

    test "is saved as made by whoever asked for it", %{proposal: proposal, ctx: ctx} do
      person = scope_fixture(user_fixture())
      {:ok, _} = Runs.submit(person, PlannerCommand, proposal, ctx)

      assert %{created_by: by} =
               Enum.find(Recipes.list(home_scope()), &(&1.title == "Tofu ramen"))

      assert by == person.user_id
    end

    test "undo still works after the recipe was deleted by hand", %{
      proposal: proposal,
      ctx: ctx
    } do
      {:ok, applied} = Runs.submit(home_scope(), PlannerCommand, proposal, ctx)
      recipe = Enum.find(Recipes.list(home_scope()), &(&1.title == "Tofu ramen"))
      {:ok, _} = Recipes.delete(home_scope(), recipe)

      assert {:ok, %KitchenRun{status: :reverted}} = Runs.revert(home_scope(), applied.id)
    end

    test "a pinned day is left alone, and nothing is saved", %{
      plan: plan,
      proposal: proposal,
      ctx: ctx
    } do
      {:ok, _} = Planning.pin_slot(home_scope(), plan, "tue_dinner", true)

      assert {:ok, %KitchenRun{status: :failed, failure_code: :slot_pinned}} =
               Runs.submit(home_scope(), PlannerCommand, proposal, ctx)

      refute Enum.any?(Recipes.list(home_scope()), &(&1.title == "Tofu ramen"))
    end

    test "a day marked eating out is left alone", %{plan: plan, proposal: proposal, ctx: ctx} do
      {:ok, _} = Planning.eat_out(home_scope(), plan, "tue_dinner", %{})

      assert {:ok, %KitchenRun{status: :failed, failure_code: :slot_eating_out}} =
               Runs.submit(home_scope(), PlannerCommand, proposal, ctx)

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
