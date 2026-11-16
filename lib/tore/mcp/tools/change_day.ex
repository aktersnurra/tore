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
    `place` and the `amount` in kronor, if known). A pinned day only changes by `unpin`.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "date" => %{"type" => "string", "format" => "date"},
        "action" => %{"type" => "string", "enum" => @actions},
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
         {:ok, reply} <- change(action, date, args, Tool.ctx(scope)) do
      Tool.reply(reply)
    end
  end

  def call(_scope, _args),
    do: {:error, "change_day needs date and an action: #{Enum.join(@actions, ", ")}."}

  defp change("clear", date, _args, ctx), do: {:ok, Dispatch.clear_plan_slot(date, ctx)}
  defp change("skip", date, _args, ctx), do: {:ok, Dispatch.skip_plan_meal(date, ctx)}
  defp change("pin", date, _args, ctx), do: {:ok, Dispatch.pin_plan_slot(date, true, ctx)}
  defp change("unpin", date, _args, ctx), do: {:ok, Dispatch.pin_plan_slot(date, false, ctx)}

  defp change("servings", date, %{"servings" => n}, ctx) when is_integer(n) and n > 0,
    do: {:ok, Dispatch.set_plan_servings(date, n, ctx)}

  defp change("servings", _date, _args, _ctx),
    do: {:error, "servings needs servings, a whole number above 0."}

  defp change("eat_out", date, args, ctx),
    do:
      {:ok, Dispatch.mark_eating_out(date, %{place: args["place"], amount: args["amount"]}, ctx)}
end
