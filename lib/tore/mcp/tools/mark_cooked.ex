defmodule Tore.Mcp.Tools.MarkCooked do
  @moduledoc "Records that a recipe was cooked today."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "mark_cooked"

  @impl true
  def description, do: "Records that a recipe was cooked today, so planning knows how recently."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"recipe_id" => %{"type" => "integer"}},
      "required" => ["recipe_id"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"recipe_id" => id}) when is_integer(id) do
    case Tore.Recipes.get(scope, id) do
      nil -> {:error, "No recipe #{id} in this household."}
      _recipe -> Tool.reply(Dispatch.mark_recipe_cooked(id, Tool.ctx(scope)))
    end
  end

  def call(_scope, _args), do: {:error, "mark_cooked needs recipe_id, a number."}
end
