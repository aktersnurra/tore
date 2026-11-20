defmodule Tore.Mcp.Tools.UpdateRecipe do
  @moduledoc """
  Replaces a saved recipe with pi's revised version of it (`Tore.Harness.Kinds.RecipeEdit`): the
  same shape `get_recipe` gives and `save_recipe` takes, so a recipe can be read, changed and
  sent back whole. Undo puts the old one back.
  """
  @behaviour Tore.Mcp.Tool

  use Gettext, backend: ToreWeb.Gettext

  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.RecipeEdit
  alias Tore.Harness.Kinds
  alias Tore.Mcp.Tools.SaveRecipe

  @impl true
  def name, do: "update_recipe"

  @impl true
  def description,
    do: """
    Replaces a recipe with your revised version of it, to refine it or adapt it (simpler, \
    vegetarian, for 6, steps fixed or written). Read it with get_recipe, change what was asked \
    and nothing else, and send the whole recipe back with its recipe_id, following save_recipe's \
    rules. Undo puts the old one back. To keep the original as well, save the new one with \
    save_recipe instead.\
    """

  @impl true
  def schema do
    schema = SaveRecipe.schema()

    schema
    |> put_in(["properties", "recipe_id"], %{"type" => "integer"})
    |> Map.update!("required", &["recipe_id" | &1])
  end

  @impl true
  def call(scope, %{"recipe_id" => id, "title" => title, "ingredients" => [_ | _]} = args)
      when is_integer(id) and is_binary(title) do
    edit = %RecipeEdit{recipe_id: id, recipe: Map.drop(args, ["recipe_id", "image_url"])}

    case Runs.submit(scope, Kinds.RecipeEdit, edit, %{edit: edit, actor: :mcp}) do
      {:ok, %KitchenRun{status: :applied, id: run_id}} ->
        {:ok, %{done: gettext("Updated %{title}.", title: title), run_id: run_id}}

      {:ok, %KitchenRun{failure_code: code}} ->
        {:error, "Not updated: #{code}."}

      {:error, reason} ->
        {:error, "Not updated: #{inspect(reason)}."}
    end
  end

  def call(_scope, _args),
    do: {:error, "update_recipe needs recipe_id, a title and at least one ingredient."}
end
