defmodule Tore.Mcp.Tools.AddToPantry do
  @moduledoc """
  Says something is at home: brought in, or seen there, as on a photo of a shelf or the fridge.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool
  alias Tore.Pantry.Expiry

  @impl true
  def name, do: "add_to_pantry"

  @impl true
  def description,
    do: """
    Records that something is at home, with how much if known. Set `seen` when you see it there, \
    as on a photo of a shelf or the fridge: then the quantity is what's there now rather than what \
    came in, `best_before` is a date printed on it, and `keeps_days` is your guess at how many \
    days this food keeps once bought. One call per item.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string"},
        "quantity" => %{"type" => "number", "exclusiveMinimum" => 0},
        "unit" => %{"type" => "string"},
        "seen" => %{"type" => "boolean"},
        "best_before" => %{"type" => "string", "format" => "date"},
        "keeps_days" => %{"type" => "integer", "minimum" => 1, "maximum" => 3650}
      },
      "required" => ["name"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"name" => name} = args) when is_binary(name) do
    with {:ok, seen} <- seen(args) do
      Tool.reply(
        Dispatch.add_to_pantry(name, args["quantity"], args["unit"], Tool.ctx(scope), seen)
      )
    end
  end

  def call(_scope, _args), do: {:error, "add_to_pantry needs a name."}

  defp seen(%{"seen" => true} = args) do
    with {:ok, printed} <- best_before(args["best_before"]) do
      {:ok, %{expires_on: printed, shelf_life_days: Expiry.parse_shelf_life(args["keeps_days"])}}
    end
  end

  defp seen(_args), do: {:ok, nil}

  defp best_before(nil), do: {:ok, nil}
  defp best_before(value), do: Tool.date(value)
end
