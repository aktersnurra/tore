defmodule Tore.Mcp.Tools.DeleteRecipe do
  @moduledoc "Deletes a recipe, as Capture does. There is no undo."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "delete_recipe"

  @impl true
  def description, do: "Deletes a recipe from the household's collection. This can't be undone."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"recipe_id" => %{"type" => "integer"}},
      "required" => ["recipe_id"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"recipe_id" => id}) when is_integer(id),
    do: Tool.reply(Dispatch.delete_recipe(id, Tool.ctx(scope)))

  def call(_scope, _args), do: {:error, "delete_recipe needs recipe_id, a number."}
end
