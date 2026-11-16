defmodule Tore.Mcp.Tools.AddToList do
  @moduledoc "Adds items to this week's shopping list, each as its own change with its own undo."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "add_to_list"

  @impl true
  def description,
    do: """
    Adds items to this week's shopping list. Write names as the household would, in its \
    language. Each item comes back with its own run_id for undo.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 50,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"},
              "quantity" => %{"type" => "number", "exclusiveMinimum" => 0},
              "unit" => %{"type" => "string"}
            },
            "required" => ["name"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["items"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"items" => [_ | _] = items}) do
    if Enum.all?(items, &(is_map(&1) and is_binary(&1["name"]) and String.trim(&1["name"]) != "")) do
      ctx = Tool.ctx(scope)

      results =
        for item <- items do
          Dispatch.add_to_shopping_list(
            String.trim(item["name"]),
            item["quantity"],
            item["unit"],
            ctx
          )
          |> Tool.reply()
        end

      {:ok,
       %{
         added: for({:ok, done} <- results, do: done),
         failed: for({:error, why} <- results, do: why)
       }}
    else
      {:error, "Every item needs a name."}
    end
  end

  def call(_scope, _args), do: {:error, "add_to_list needs items, each with a name."}
end
