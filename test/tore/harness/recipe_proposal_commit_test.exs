defmodule Tore.Harness.RecipeProposalCommitTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run.State

  setup do
    household = Tore.Household.get_household!()
    plan_stream_id = "plan:" <> Ecto.UUID.generate()
    {:ok, household: household, plan_stream_id: plan_stream_id}
  end

  defp proposal(overrides \\ %{}) do
    base = %RecipeProposal{
      title: "Vegetarian Miso Ramen",
      description: "No pork.",
      instructions: "Simmer the broth. Add tofu.",
      base_servings: 4,
      prep_time_minutes: 10,
      cook_time_minutes: 20,
      ingredients: [
        %{name: "miso paste", quantity: "2", unit: "msk"},
        %{name: "firm tofu", quantity: "300", unit: "g"}
      ],
      tags: ["vegetarian"],
      source: :generation,
      source_recipe_id: nil,
      instruction: "make it vegetarian",
      pending_assignment: nil
    }

    struct!(base, overrides)
  end

  # Drive a run to :needs_user by having the planner call a proposal tool.
  defp needs_user_run(ctx, proposal) do
    proposal_tool = %Tore.LLM.Tool{
      name: "fake_proposal_tool",
      description: "test double",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _args, _c, plan ->
        {:proposal, proposal, proposal.pending_assignment || %{}, plan}
      end
    }

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "fake_proposal_tool", args: %{}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, %State.NeedsUser{} = state} =
      Orchestrator.dispatch(:planner_command_run, %{
        household_id: ctx.household.id,
        user_id: nil,
        command: "make it vegetarian",
        plan_stream_id: ctx.plan_stream_id,
        week_start: ~D[2026-08-17],
        extra_tools: [proposal_tool]
      })

    state
  end

  test "committing saves the recipe to the catalog", ctx do
    state = needs_user_run(ctx, proposal())

    assert {:ok, %State.Applied{}} =
             Orchestrator.commit_recipe_proposal(home_scope(), state.stream_id, proposal(), nil)

    assert [recipe] = Tore.Recipes.list(home_scope())
    recipe = Tore.Recipes.get!(home_scope(), recipe.id)
    assert recipe.title == "Vegetarian Miso Ramen"
    assert length(recipe.recipe_ingredients) == 2
  end

  test "committing with a pending assignment slots the new recipe", ctx do
    pending = %{slot_key: "mon_dinner", servings: 4}
    p = proposal(%{pending_assignment: pending})
    state = needs_user_run(ctx, p)

    assert {:ok, %State.Applied{}} =
             Orchestrator.commit_recipe_proposal(home_scope(), state.stream_id, p, nil)

    {:ok, plan} = Tore.Planning.load_plan(home_scope(), ctx.plan_stream_id)
    [recipe] = Tore.Recipes.list(home_scope())

    assert get_in(plan.slots, ["mon_dinner", :recipe_id]) == recipe.id
  end

  test "committing an edited proposal saves the edits, not the original", ctx do
    state = needs_user_run(ctx, proposal())

    edited = proposal(%{title: "Vegan Miso Ramen"})

    assert {:ok, %State.Applied{}} =
             Orchestrator.commit_recipe_proposal(home_scope(), state.stream_id, edited, nil)

    assert [%{title: "Vegan Miso Ramen"}] = Tore.Recipes.list(home_scope())
  end

  test "committing an edit that fails the verifier saves nothing", ctx do
    state = needs_user_run(ctx, proposal())

    broken = proposal(%{ingredients: []})

    assert {:error, {:verifier_failed, :no_ingredients, :reject}} =
             Orchestrator.commit_recipe_proposal(home_scope(), state.stream_id, broken, nil)

    assert Tore.Recipes.list(home_scope()) == []
  end

  test "discarding saves nothing and leaves the slot untouched", ctx do
    pending = %{slot_key: "mon_dinner", servings: 4}
    p = proposal(%{pending_assignment: pending})
    state = needs_user_run(ctx, p)

    assert {:ok, %State.Discarded{}} =
             Orchestrator.discard_run(home_scope(), state.stream_id, reason: :user_discarded)

    assert Tore.Recipes.list(home_scope()) == []

    {:ok, plan} = Tore.Planning.load_plan(home_scope(), ctx.plan_stream_id)
    assert get_in(plan.slots, ["mon_dinner", :recipe_id]) == nil
  end

  test "committing a run that is not awaiting the user is rejected", ctx do
    state = needs_user_run(ctx, proposal())
    {:ok, _} = Orchestrator.commit_recipe_proposal(home_scope(), state.stream_id, proposal(), nil)

    assert {:error, :already_applied} =
             Orchestrator.commit_recipe_proposal(home_scope(), state.stream_id, proposal(), nil)
  end
end
