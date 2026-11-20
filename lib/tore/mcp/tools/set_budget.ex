defmodule Tore.Mcp.Tools.SetBudget do
  @moduledoc "The household's weekly budget from a week on, or one week's own (`Tore.Capture.Dispatch.set_budget/3`)."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "set_budget"

  @impl true
  def description,
    do: """
    What the household's whole weekly shop should cost, in kronor. Without dates, the usual \
    budget from this week on; with from (any date in a week), from that week on, so earlier \
    weeks keep theirs; with week_of, only that week. amount null removes it. \
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
        },
        "from" => %{
          "type" => "string",
          "description" => "ISO date in the first week the budget holds for."
        }
      },
      "required" => ["amount"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"amount" => amount} = args)
      when is_nil(amount) or (is_number(amount) and amount > 0) do
    with {:ok, which} <- which(args["week_of"], args["from"]),
         do: Tool.reply(Dispatch.set_budget(Tore.Types.decimal(amount), which, Tool.ctx(scope)))
  end

  def call(_scope, _args), do: {:error, "set_budget needs amount: kronor above 0, or null."}

  defp which(nil, nil), do: {:ok, {:from, Tore.Clock.today()}}
  defp which(nil, from), do: with({:ok, date} <- Tool.date(from), do: {:ok, {:from, date}})
  defp which(week_of, nil), do: with({:ok, date} <- Tool.date(week_of), do: {:ok, {:week, date}})
  defp which(_week_of, _from), do: {:error, "Give week_of or from, not both."}
end
