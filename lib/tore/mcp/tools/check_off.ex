defmodule Tore.Mcp.Tools.CheckOff do
  @moduledoc "Ticks an item on this week's list, which puts it in the pantry, as a tick in the app does."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "check_off"

  @impl true
  def description,
    do:
      "Ticks an item on this week's shopping list by name: it's bought, and goes into the pantry."

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
    do: Tool.reply(Dispatch.check_off_shopping_item(name, Tool.ctx(scope)))

  def call(_scope, _args), do: {:error, "check_off needs the item's name."}
end
