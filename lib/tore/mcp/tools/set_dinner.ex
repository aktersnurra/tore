defmodule Tore.Mcp.Tools.SetDinner do
  @moduledoc "Puts a recipe on a day's dinner, or its lunch, as Capture's `set_plan_slot` does."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "set_dinner"

  @impl true
  def description,
    do: """
    Puts a recipe on a day's dinner, replacing what was there, or on its lunch with \
    `meal: "lunch"` (only when they ask for a lunch). A pinned day stays as it is. Servings \
    default to 4.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "date" => %{"type" => "string", "format" => "date"},
        "recipe_id" => %{"type" => "integer"},
        "meal" => %{"type" => "string", "enum" => ["dinner", "lunch"]},
        "servings" => %{"type" => "integer", "minimum" => 1}
      },
      "required" => ["date", "recipe_id"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"recipe_id" => id} = args) when is_integer(id) do
    servings = if is_integer(args["servings"]) and args["servings"] > 0, do: args["servings"]

    with {:ok, date} <- Tool.date(args["date"]) do
      Tool.reply(Dispatch.set_plan_slot(date, id, servings, Tool.ctx(scope), Tool.meal(args)))
    end
  end

  def call(_scope, _args), do: {:error, "set_dinner needs date and recipe_id, a number."}
end
