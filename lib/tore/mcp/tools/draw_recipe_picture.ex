defmodule Tore.Mcp.Tools.DrawRecipePicture do
  @moduledoc """
  Draws a recipe's picture from pi's description of the dish, in Tore's house style
  (`Tore.Recipes.draw_picture/3`), and sets it with a `:recipe_edit_run`, so undo puts the old
  picture back. A paid image call, so it goes through the household's AI gate.
  """
  @behaviour Tore.Mcp.Tool

  use Gettext, backend: ToreWeb.Gettext

  alias Tore.{Pi, Recipes}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.RecipeEdit
  alias Tore.Harness.Kinds

  @impl true
  def name, do: "draw_recipe_picture"

  @impl true
  def description,
    do: """
    Draws the recipe's picture, replacing the one it has. `dish` describes the finished food, \
    in 30-60 words of English for an image model: what it is and only what the eye sees of it, \
    its colours and textures. An image model draws every thing named, up front, so leave out \
    spices and flavourings cooked in (cloves in a bread, zest or star anise in a glaze); a \
    garnish only if one is really put on top. Then what shows best (a bun torn open showing its \
    swirl), how much of it there is (a cake or tart: the whole with one piece cut out, or one \
    piece), the sides \
    served with it, what each is really served in at home (the pan or tin it was cooked in, a \
    wooden board, a glazed bowl in some colour, baking paper on a tray; a plain plate now and \
    then, varied with the dish), and one small sign it's about to be eaten that suits it (a \
    spoonful gone from a soup, a fork resting in a pasta). Nothing the recipe doesn't have, and \
    no surface, light, style or angle: Tore sets those, so every picture looks like one feed. \
    Takes up to a minute. Undo puts the old picture back.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "recipe_id" => %{"type" => "integer"},
        "dish" => %{"type" => "string", "minLength" => 1}
      },
      "required" => ["recipe_id", "dish"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"recipe_id" => id, "dish" => dish}) when is_integer(id) and is_binary(dish) do
    with %{} <- Recipes.get(scope, id) || {:error, "No recipe #{id} in this household."},
         :ok <- gate(scope),
         {:ok, key} <- drawn(Recipes.draw_picture(scope, id, dish)) do
      edit = %RecipeEdit{recipe_id: id, image_path: key}

      case Runs.submit(scope, Kinds.RecipeEdit, edit, %{edit: edit, actor: :mcp}) do
        {:ok, %KitchenRun{status: :applied, id: run_id}} ->
          {:ok, %{done: gettext("Drew a new picture."), run_id: run_id}}

        {:ok, %KitchenRun{failure_code: code}} ->
          {:error, "Not drawn: #{code}."}

        {:error, reason} ->
          {:error, "Not drawn: #{inspect(reason)}."}
      end
    end
  end

  def call(_scope, _args),
    do: {:error, "draw_recipe_picture needs recipe_id, a number, and dish, a description."}

  defp gate(scope) do
    case Pi.check(scope) do
      :ok -> :ok
      {:error, reason} -> {:error, "Pictures are off for this household: #{reason}."}
    end
  end

  defp drawn({:ok, key}), do: {:ok, key}
  defp drawn({:error, reason}), do: {:error, "The picture couldn't be drawn: #{inspect(reason)}."}
end
