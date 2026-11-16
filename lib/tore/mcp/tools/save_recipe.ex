defmodule Tore.Mcp.Tools.SaveRecipe do
  @moduledoc """
  Saves a recipe Claude read from a page or a photo. It sends the same shape Tore's own recipe
  parser produces (`Tore.LLM.Prompts.recipe_json_schema/0`), so one conversion serves both, and the
  run passes `RecipeProposalVerifier` like any recipe.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.Recipes
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Kinds.RecipeIngestion

  @impl true
  def name, do: "save_recipe"

  @impl true
  def description,
    do: """
    Saves a recipe you read from a page or a photo, in the household's language. Ingredients \
    are `item`, `quantity` and `unit`; steps are single actions in cooking order, grouped by a \
    `phase` in capitals (MISE EN PLACE, SAUCE, …), with `duration_minutes` for a step that waits. \
    Give `source_url` for a page, and `image_url` for the page's own picture. A recipe the \
    household already has is refused.\
    """

  @impl true
  def schema do
    schema = Tore.LLM.Prompts.recipe_json_schema().json_schema.schema

    schema
    |> Map.put(:required, ["title", "ingredients", "steps"])
    |> put_in([:properties, :source_url], %{type: ["string", "null"]})
    |> put_in([:properties, :ingredients, :items, :required], ["item"])
    |> put_in([:properties, :steps, :items, :required], ["order", "action"])
    |> Jason.encode!()
    |> Jason.decode!()
  end

  @impl true
  def call(scope, %{"title" => title, "ingredients" => [_ | _], "steps" => [_ | _]} = args)
      when is_binary(title) do
    url = args["source_url"]
    source = if is_binary(url) and url != "", do: :web_import, else: :photo
    proposal = args |> Recipes.attrs_from_parsed() |> RecipeProposal.from_attrs(source, url)

    case Runs.submit(scope, RecipeIngestion, proposal, %{proposal: proposal, actor: :mcp}) do
      {:ok, %KitchenRun{status: :applied, id: id, undo: {:steps, steps}}} ->
        [recipe_id] = for {:delete_recipe, recipe_id} <- steps, do: recipe_id
        {:ok, %{done: "Saved #{title}.", run_id: id, recipe_id: recipe_id}}

      {:ok, %KitchenRun{failure_code: code}} ->
        {:error, "Not saved: #{code}."}

      {:error, reason} ->
        {:error, "Not saved: #{inspect(reason)}."}
    end
  end

  def call(_scope, _args),
    do: {:error, "save_recipe needs a title, at least one ingredient and at least one step."}
end
