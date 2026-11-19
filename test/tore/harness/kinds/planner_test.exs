defmodule Tore.Harness.Kinds.PlannerTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Planning, Recipes}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Kinds.{RecipeIngestion, SetPlanSlot}
  alias Tore.Planning.{Commands, Decider, State}

  setup :verify_on_exit!

  @week ~D[2026-06-08]

  setup do
    stub(Tore.MockHTTP, :fetch, fn _url -> {:error, :not_found} end)
    plan = Tore.Streams.plan(home_scope(), @week)
    {:ok, recipe} = Recipes.create(home_scope(), recipe("Stew"))
    {:ok, _} = Planning.assign_recipe(home_scope(), plan, "mon_dinner", recipe.id, 4)
    %{plan: plan, recipe: recipe}
  end

  defp recipe(title),
    do: %{
      title: title,
      recipe_type: :meal,
      base_servings: 4,
      image_url: "https://example.com/x.jpg"
    }

  defp slots(plan) do
    {:ok, state} = Planning.load_plan(home_scope(), plan)
    {state.slots, state.pins}
  end

  describe "a saved recipe" do
    setup do
      proposal = %RecipeProposal{
        title: "Tofu ramen",
        instructions: "Simmer.",
        base_servings: 4,
        ingredients: [%{name: "tofu", quantity: "300", unit: "g"}],
        tags: [],
        source: :web_import
      }

      %{proposal: proposal, ctx: %{proposal: proposal}}
    end

    test "is saved as made by whoever asked for it", %{proposal: proposal, ctx: ctx} do
      person = scope_fixture(user_fixture())
      {:ok, _} = Runs.submit(person, RecipeIngestion, proposal, ctx)

      assert %{created_by: by} =
               Enum.find(Recipes.list(home_scope()), &(&1.title == "Tofu ramen"))

      assert by == person.user_id
    end

    test "undo still works after the recipe was deleted by hand", %{
      proposal: proposal,
      ctx: ctx
    } do
      {:ok, applied} = Runs.submit(home_scope(), RecipeIngestion, proposal, ctx)
      recipe = Enum.find(Recipes.list(home_scope()), &(&1.title == "Tofu ramen"))
      {:ok, _} = Recipes.delete(home_scope(), recipe)

      assert {:ok, %KitchenRun{status: :reverted}} = Runs.revert(home_scope(), applied.id)
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
