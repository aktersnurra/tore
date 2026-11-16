defmodule Tore.Mcp.Tools.MakeList do
  @moduledoc "Builds a week's shopping list from its plan, as Capture does."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "make_list"

  @impl true
  def description,
    do: """
    Builds the shopping list from a week's planned dinners, leaving out what the pantry holds. \
    It replaces that week's list. `date` is any day in the week; without it, this week.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"date" => %{"type" => "string", "format" => "date"}},
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"date" => value}) do
    with {:ok, date} <- Tool.date(value),
         do: Tool.reply(Dispatch.generate_shopping_list_from_plan(date, Tool.ctx(scope)))
  end

  def call(scope, _args),
    do: Tool.reply(Dispatch.generate_shopping_list_from_plan(nil, Tool.ctx(scope)))
end
