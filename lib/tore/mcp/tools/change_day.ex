defmodule Tore.Mcp.Tools.ChangeDay do
  @moduledoc "One change to a day's dinner other than choosing the recipe, as Capture's day tools."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @actions ~w(clear skip pin unpin servings eat_out)

  @impl true
  def name, do: "change_day"

  @impl true
  def description,
    do: """
    Changes a day's dinner: `clear` takes the recipe off, `skip` keeps it but skips the day, \
    `pin` keeps the day as it is through any replanning and `unpin` lets it go, `servings` sets \
    how many it's for (give `servings`), and `eat_out` marks the day as eating out (with \
    `place` and the `amount` in kronor, if known). A pinned day only changes by `unpin`. \
    `meal: "lunch"` changes the day's lunch instead (clear, pin, unpin or servings; a lunch \
    that isn't happening is cleared, not skipped).\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "date" => %{"type" => "string", "format" => "date"},
        "action" => %{"type" => "string", "enum" => @actions},
        "meal" => %{"type" => "string", "enum" => ["dinner", "lunch"]},
        "servings" => %{"type" => "integer", "minimum" => 1},
        "place" => %{"type" => "string"},
        "amount" => %{"type" => "number", "minimum" => 0}
      },
      "required" => ["date", "action"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"action" => action} = args) when action in @actions do
    with {:ok, date} <- Tool.date(args["date"]),
         {:ok, reply} <- change(action, {date, Tool.meal(args)}, args, Tool.ctx(scope)) do
      Tool.reply(reply)
    end
  end

  def call(_scope, _args),
    do: {:error, "change_day needs date and an action: #{Enum.join(@actions, ", ")}."}

  defp change("clear", {date, meal}, _args, ctx),
    do: {:ok, Dispatch.clear_plan_slot(date, ctx, meal)}

  defp change("pin", {date, meal}, _args, ctx),
    do: {:ok, Dispatch.pin_plan_slot(date, true, ctx, meal)}

  defp change("unpin", {date, meal}, _args, ctx),
    do: {:ok, Dispatch.pin_plan_slot(date, false, ctx, meal)}

  defp change("servings", {date, meal}, %{"servings" => n}, ctx) when is_integer(n) and n > 0,
    do: {:ok, Dispatch.set_plan_servings(date, n, ctx, meal)}

  defp change("servings", _date, _args, _ctx),
    do: {:error, "servings needs servings, a whole number above 0."}

  defp change(action, {_date, :lunch}, _args, _ctx) when action in ~w(skip eat_out),
    do: {:error, "A lunch isn't skipped or eaten out; clear it instead."}

  defp change("skip", {date, :dinner}, _args, ctx), do: {:ok, Dispatch.skip_plan_meal(date, ctx)}

  defp change("eat_out", {date, :dinner}, args, ctx),
    do:
      {:ok, Dispatch.mark_eating_out(date, %{place: args["place"], amount: args["amount"]}, ctx)}
end
