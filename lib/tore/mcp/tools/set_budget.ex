defmodule Tore.Mcp.Tools.SetBudget do
  @moduledoc "The household's weekly budget, or one week's own, under the same rules as Capture's `set_budget`."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "set_budget"

  @impl true
  def description,
    do: """
    What the household's whole weekly shop should cost, in kronor. With week_of (any date in the \
    week), only that week; without, the usual budget for every week. amount null removes it. \
    Tore's weekly plan aims at it and never changes a dinner someone chose; get_context shows \
    each week's estimate against it.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "amount" => %{"type" => ["number", "null"], "exclusiveMinimum" => 0},
        "week_of" => %{
          "type" => "string",
          "description" => "ISO date in the week, like 2026-11-18."
        }
      },
      "required" => ["amount"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"amount" => amount} = args)
      when is_nil(amount) or (is_number(amount) and amount > 0) do
    with {:ok, date} <- week_of(args["week_of"]),
         do: Tool.reply(Dispatch.set_budget(Tore.Types.decimal(amount), date, Tool.ctx(scope)))
  end

  def call(_scope, _args), do: {:error, "set_budget needs amount: kronor above 0, or null."}

  defp week_of(nil), do: {:ok, nil}
  defp week_of(value), do: Tool.date(value)
end
