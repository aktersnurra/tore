defmodule Tore.Mcp.Tools.AddToPantry do
  @moduledoc "Says something is at home, as telling Capture does."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "add_to_pantry"

  @impl true
  def description, do: "Records that something is at home, with how much if known."

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "quantity" => %{"type" => "number", "exclusiveMinimum" => 0},
        "unit" => %{"type" => "string"}
      },
      "required" => ["name"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"name" => name} = args) when is_binary(name),
    do: Tool.reply(Dispatch.add_to_pantry(name, args["quantity"], args["unit"], Tool.ctx(scope)))

  def call(_scope, _args), do: {:error, "add_to_pantry needs a name."}
end
