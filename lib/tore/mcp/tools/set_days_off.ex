defmodule Tore.Mcp.Tools.SetDaysOff do
  @moduledoc "Marks days the household is off, or takes them back, as Capture's `set_days_off`."
  @behaviour Tore.Mcp.Tool

  alias Tore.Capture.Dispatch
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "set_days_off"

  @impl true
  def description,
    do: """
    Marks days the household is off work or school ("we're off week 29", "off on Friday"), or \
    with `off: false` takes them back. A day off offers a lunch on the plan; it doesn't plan \
    one, and nothing else changes. Weekends and Swedish public holidays need nothing.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "dates" => %{
          "type" => "array",
          "items" => %{"type" => "string", "format" => "date"},
          "minItems" => 1
        },
        "off" => %{"type" => "boolean"}
      },
      "required" => ["dates"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"dates" => [_ | _] = strs} = args) do
    with {:ok, dates} <- dates(strs) do
      Tool.reply(Dispatch.set_days_off(dates, args["off"] != false, Tool.ctx(scope)))
    end
  end

  def call(_scope, _args), do: {:error, "set_days_off needs dates, a list of ISO dates."}

  defp dates(strs) do
    Enum.reduce_while(Enum.reverse(strs), {:ok, []}, fn str, {:ok, acc} ->
      case Tool.date(str) do
        {:ok, date} -> {:cont, {:ok, [date | acc]}}
        error -> {:halt, error}
      end
    end)
  end
end
