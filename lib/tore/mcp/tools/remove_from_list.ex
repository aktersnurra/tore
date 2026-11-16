defmodule Tore.Mcp.Tools.RemoveFromList do
  @moduledoc "Takes an item off this week's list, as removing it in the app does."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "remove_from_list"

  @impl true
  def description, do: "Takes an item off this week's shopping list by name, without buying it."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "required" => ["name"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"name" => name}) when is_binary(name),
    do: Tool.reply(Dispatch.remove_shopping_item(name, Tool.ctx(scope)))

  def call(_scope, _args), do: {:error, "remove_from_list needs the item's name."}
end
