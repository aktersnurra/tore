defmodule Tore.RunFixtures do
  @moduledoc "Runs in a given status, for tests of what reads them."

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.KitchenRun
  alias Tore.Harness.KitchenRun.Transition
  alias Tore.Repo

  @doc "A recipe waiting for review, opened at `opened_at`."
  def pending_review_fixture(scope, opened_at \\ DateTime.utc_now()) do
    proposal = %RecipeProposal{
      title: "Misoramen",
      instructions: "Sjud buljongen.",
      base_servings: 4,
      ingredients: [%{name: "tofu", quantity: "300", unit: "g"}],
      source: :photo
    }

    scope
    |> open(%{kind: "recipe_ingestion_run", input: %{}}, opened_at)
    |> move({:review, "Review this recipe before saving it."}, %{artifacts: [proposal]})
  end

  @doc "A planner run waiting on a question, which has nothing to review."
  def pending_question_fixture(scope) do
    scope
    |> open(%{kind: "planner_command_run", surface: :plan, input: %{}})
    |> move({:ask, "Which Monday?"})
  end

  defp open(scope, attrs, at \\ DateTime.utc_now()) do
    scope
    |> KitchenRun.open(Map.put(attrs, :actor, :user), at)
    |> Repo.insert!()
  end

  defp move(run, action, extra \\ %{}) do
    {:ok, changes} = Transition.next(run, action, DateTime.utc_now())
    run |> KitchenRun.change(Map.merge(changes, extra)) |> Repo.update!()
  end
end
