defmodule Tore.Mcp.Tools.RemoveFromPantry do
  @moduledoc "Says something has run out, as telling Capture does."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "remove_from_pantry"

  @impl true
  def description, do: "Records that something has run out or is gone, by name."

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
    do: Tool.reply(Dispatch.remove_from_pantry(name, Tool.ctx(scope)))

  def call(_scope, _args), do: {:error, "remove_from_pantry needs a name."}
end
