defmodule Tore.Harness.Kinds.Planner do
  @moduledoc """
  What the plan kinds share: verifying and applying a proposal.

  A proposal is a `PlanDiff`, applied straight away once `PlanVerifier` passes, or a
  `RecipeProposal`, which saves the recipe once `RecipeProposalVerifier` passes. Undo deletes
  the recipe.

  Applying records each touched slot as it was, so undo puts back what was there rather than
  clearing it. Plan screens hear about the change after the run commits.
  """

  alias Tore.{Household, Planning, Recipes, Scope}
  alias Tore.Harness.Artifact.{PlanDiff, RecipeProposal}
  alias Tore.Harness.Verifier.{PlanVerifier, RecipeProposalVerifier}
  alias Tore.Planning.Decider

  @doc "The run's input: where the plan lives, plus `extra`."
  @spec input(map(), map()) :: map()
  def input(ctx, extra \\ %{}) do
    Map.merge(
      %{"plan_stream_id" => ctx.plan_stream_id, "week_start" => Date.to_iso8601(ctx.week_start)},
      extra
    )
  end

  @spec verify(PlanDiff.t() | RecipeProposal.t(), map()) :: :ok | {:fail, atom(), term()}
  def verify(%PlanDiff{} = diff, %{scope: scope}) do
    {:ok, plan} = Planning.load_plan(scope, diff.plan_stream_id)

    PlanVerifier.verify(diff, %{
      plan_state: Enum.reduce(diff.plan_events, plan, &Decider.evolve(&2, &1)),
      plan_before: plan,
      preferences: Household.get_preferences(scope),
      scope: scope
    })
  end

  def verify(%RecipeProposal{} = proposal, %{scope: scope}),
    do:
      RecipeProposalVerifier.verify(proposal, %{
        existing_recipes: Recipes.catalog_fingerprints(scope)
      })

  # Nothing waits for review: a recipe is saved straight away, and undo deletes it.
  @spec review_question(PlanDiff.t() | RecipeProposal.t()) :: nil
  def review_question(_proposal), do: nil

  @spec apply_proposal(PlanDiff.t() | RecipeProposal.t(), map()) ::
          {:ok, Tore.Harness.Undo.t(), [struct()]} | {:fail, atom(), term()} | {:error, term()}
  def apply_proposal(%PlanDiff{} = diff, %{scope: scope}) do
    with {:ok, undo} <- change_plan(scope, diff.plan_stream_id, diff.plan_events) do
      {:ok, {:steps, undo}, [diff]}
    end
  end

  def apply_proposal(%RecipeProposal{} = proposal, %{scope: scope, run: run}) do
    # On confirm the scope is the person confirming; a weekly run opened as the system has no user.
    user_id = scope.user_id || run.user_id

    with {:ok, recipe} <- Recipes.create(scope, recipe_attrs(proposal, user_id), image: false) do
      {:ok, {:steps, [{:delete_recipe, recipe.id}]}, [proposal]}
    end
  end

  @spec after_commit(Tore.Harness.KitchenRun.t()) :: :ok
  def after_commit(%{status: :applied} = run) do
    scope = Scope.for_household(run.household_id)

    # A confirmed recipe gets its picture now that the recipe is committed, generated in Tore's
    # house style so the library looks like one cookbook; a page's own photo isn't used. MCP
    # never reaches the server's model, so a recipe saved over MCP takes its page's photo, or
    # stays without one.
    image_url = Enum.find_value(run.artifacts, &(match?(%RecipeProposal{}, &1) && &1.image_url))
    image_url = if run.actor == :mcp, do: image_url

    with {:steps, steps} <- run.undo,
         true <- image_url != nil or run.actor != :mcp,
         do: for({:delete_recipe, id} <- steps, do: Recipes.start_image(scope, id, image_url))

    Planning.announce(scope)
  end

  def after_commit(%{status: :reverted} = run),
    do: Planning.announce(Scope.for_household(run.household_id))

  def after_commit(_run), do: :ok

  @doc "Appends `events` and returns the undo steps that put the touched slots back."
  @spec change_plan(Scope.t(), String.t(), [Tore.Planning.Events.t()]) ::
          {:ok, [Tore.Harness.Undo.step()]} | {:error, term()}
  def change_plan(_scope, _plan_id, []), do: {:ok, []}

  def change_plan(scope, plan_id, events) do
    {:ok, plan} = Planning.load_plan(scope, plan_id)
    before = Planning.slots_before(plan, events |> Enum.map(& &1.slot_key) |> Enum.uniq())

    with :ok <- Planning.append_events(scope, plan_id, events) do
      {:ok, [{:restore_plan_slots, plan_id, before}]}
    end
  end

  defp recipe_attrs(%RecipeProposal{} = proposal, user_id) do
    %{
      title: proposal.title,
      recipe_type: proposal.recipe_type || :meal,
      description: proposal.description,
      instructions: proposal.instructions,
      base_servings: proposal.base_servings,
      prep_time_minutes: proposal.prep_time_minutes,
      cook_time_minutes: proposal.cook_time_minutes,
      source_url: proposal.source_url,
      steps: proposal.steps,
      created_by: user_id,
      tags: proposal.tags,
      ingredients: Enum.map(proposal.ingredients, &ingredient_attrs/1)
    }
  end

  defp ingredient_attrs(ing),
    do: %{name: ing[:name], quantity: Tore.Types.decimal(ing[:quantity]), unit: ing[:unit]}
end
