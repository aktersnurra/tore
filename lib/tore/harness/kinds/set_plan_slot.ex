defmodule Tore.Harness.Kinds.SetPlanSlot do
  @moduledoc """
  Capture puts a recipe on a day. Submitted with its proposal already made, so there is no LLM
  step, but it passes `PlanVerifier` like any planner change: a pinned day stays as it is.
  """

  @behaviour Tore.Harness.Kind

  alias Tore.{Recipes, Scope, Streams}
  alias Tore.Harness.Artifact.PlanDiff
  alias Tore.Harness.Kinds.Planner
  alias Tore.Planning.Events.RecipeAssigned

  @doc """
  The proposal for putting `recipe_id` on `date`'s dinner (or lunch), and the ctx to submit it with.
  """
  @spec proposal(Scope.t(), Date.t(), integer(), integer(), Streams.meal()) ::
          {:ok, PlanDiff.t(), map()} | {:error, :recipe_not_found}
  def proposal(%Scope{} = scope, %Date{} = date, recipe_id, servings, meal \\ :dinner) do
    case Recipes.get(scope, recipe_id) do
      nil ->
        {:error, :recipe_not_found}

      recipe ->
        plan_id = Streams.plan(scope, date)
        slot_key = Streams.slot_key(date, meal)
        week_start = Streams.monday(date)

        diff = %PlanDiff{
          plan_stream_id: plan_id,
          week_start: week_start,
          events: [
            %{
              slot_key: slot_key,
              event_type: "RecipeAssigned",
              payload: %{
                "recipe_id" => recipe.id,
                "servings" => servings,
                "label" => recipe.title
              },
              rationale: ["user requested"]
            }
          ],
          plan_events: [
            %RecipeAssigned{slot_key: slot_key, recipe_id: recipe.id, servings: servings}
          ]
        }

        {:ok, diff, %{plan_stream_id: plan_id, week_start: week_start, slot_key: slot_key}}
    end
  end

  @impl true
  def kind, do: "set_plan_slot_run"

  @impl true
  def surface, do: :plan

  @impl true
  def open(ctx), do: %{input: Planner.input(ctx, %{"slot_key" => ctx.slot_key}), actor: :user}

  @impl true
  defdelegate verify(proposal, ctx), to: Planner

  @impl true
  defdelegate review_question(proposal), to: Planner

  @impl true
  defdelegate apply_proposal(proposal, ctx), to: Planner

  @impl true
  defdelegate after_commit(run), to: Planner
end
