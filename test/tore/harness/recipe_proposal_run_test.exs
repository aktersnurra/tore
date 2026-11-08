defmodule Tore.Harness.RecipeProposalRunTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run.State

  setup do
    household = home_household()
    plan_stream_id = "plan:" <> Ecto.UUID.generate()
    {:ok, household: household, plan_stream_id: plan_stream_id}
  end

  # See memory: Recipes.create/1's async image Task calls MockLLM.text/3 and
  # races expectations. Passing :image_url routes it to the HTTP client, which
  # the stub absorbs.
  defp source_recipe do
    stub(Tore.MockHTTP, :fetch, fn _url -> {:error, :not_found} end)

    {:ok, recipe} =
      Tore.Recipes.create(home_scope(), %{
        title: "Miso Ramen",
        instructions: "Simmer the broth.",
        base_servings: 4,
        image_url: "https://example.com/ramen.jpg",
        ingredients: [%{name: "pork belly", quantity: Decimal.new("300"), unit: "g"}]
      })

    recipe
  end

  defp variant_payload do
    %{
      "title" => "Vegetarian Miso Ramen",
      "base_servings" => 4,
      "ingredients" => [%{"item" => "firm tofu", "quantity" => 300, "unit" => "g"}],
      "steps" => [
        %{"order" => 1, "phase" => "COOKING", "action" => "Simmer.", "ingredients" => []}
      ],
      "tags" => ["vegetarian"]
    }
  end

  # The planner: first turn resolves the recipe, second turn generates.
  defp stub_planner_turns(recipe_title) do
    Tore.MockLLM
    |> expect(:chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok,
       {:tool_calls, [%{id: "c1", name: "resolve_recipe", args: %{"query" => recipe_title}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)
    |> expect(:chat_with_tools, fn _sys, msgs, _tools, _opts ->
      ref = extract_ref(msgs)

      {:ok,
       {:tool_calls,
        [
          %{
            id: "c2",
            name: "generate_recipe_variant",
            args: %{
              "recipe_ref" => ref,
              "instruction" => "make it vegetarian",
              "slot_key" => "mon_dinner",
              "servings" => 4
            }
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)
    |> expect(:text, fn _sys, _user, _opts ->
      {:ok, variant_payload(), %{prompt_tokens: 10, completion_tokens: 20, cost_usd: 0.001}}
    end)
  end

  defp extract_ref(messages) do
    messages
    |> Enum.find(&(&1[:role] == "tool" || &1["role"] == "tool"))
    |> then(fn msg -> Jason.decode!(msg[:content] || msg["content"]) end)
    |> get_in(["match", "ref"])
  end

  test "a variant request parks the run in :needs_user with the proposal attached", ctx do
    recipe = source_recipe()
    stub_planner_turns(recipe.title)

    assert {:ok, %State.NeedsUser{} = state} =
             Orchestrator.dispatch(:planner_command_run, %{
               household_id: ctx.household.id,
               user_id: nil,
               command: "make tonight's ramen vegetarian",
               plan_stream_id: ctx.plan_stream_id,
               week_start: ~D[2026-08-17]
             })

    assert [%RecipeProposal{} = proposal] =
             Enum.filter(state.artifacts, &match?(%RecipeProposal{}, &1))

    assert proposal.title == "Vegetarian Miso Ramen"
    assert proposal.source == :generation
    assert state.question =~ "Review"
  end

  test "the pending slot assignment rides on the proposal artifact", ctx do
    recipe = source_recipe()
    stub_planner_turns(recipe.title)

    {:ok, %State.NeedsUser{artifacts: artifacts}} =
      Orchestrator.dispatch(:planner_command_run, %{
        household_id: ctx.household.id,
        user_id: nil,
        command: "make tonight's ramen vegetarian",
        plan_stream_id: ctx.plan_stream_id,
        week_start: ~D[2026-08-17]
      })

    assert [%RecipeProposal{pending_assignment: pending}] =
             Enum.filter(artifacts, &match?(%RecipeProposal{}, &1))

    assert pending == %{slot_key: "mon_dinner", servings: 4}
  end

  test "a proposal failing the verifier fails the run instead of parking it", ctx do
    recipe = source_recipe()

    Tore.MockLLM
    |> expect(:chat_with_tools, fn _, _, _, _ ->
      {:ok,
       {:tool_calls, [%{id: "c1", name: "resolve_recipe", args: %{"query" => recipe.title}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)
    |> expect(:chat_with_tools, fn _, msgs, _, _ ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c2",
            name: "generate_recipe_variant",
            args: %{"recipe_ref" => extract_ref(msgs), "instruction" => "simpler"}
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)
    |> expect(:text, fn _, _, _ ->
      # No ingredients — the verifier must reject this.
      {:ok, %{"title" => "Empty Ramen", "base_servings" => 4, "ingredients" => [], "steps" => []},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    assert {:ok, %State.Failed{} = state} =
             Orchestrator.dispatch(:planner_command_run, %{
               household_id: ctx.household.id,
               user_id: nil,
               command: "simpler ramen",
               plan_stream_id: ctx.plan_stream_id,
               week_start: ~D[2026-08-17]
             })

    assert state.failure_code == :no_ingredients
  end
end
