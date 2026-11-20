defmodule Tore.Mcp.Tools.WhatIf do
  @moduledoc """
  What a week would cost with its plan changed, against what it costs now, from the forecast the
  budget page goes by (`Tore.Budget.Forecast.live/2`). Changes nothing.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.{Budget, Planning, Recipes, Streams}
  alias Tore.Budget.Forecast
  alias Tore.Mcp.Tool

  @impl true
  def name, do: "what_if"

  @impl true
  def description,
    do: """
    What the week's shop would cost if its plan changed, next to what it costs now: expected \
    kronor, an 80 % range and the risk of going over budget when the forecast gives them. Each \
    change puts a recipe on a day's dinner (or lunch, with `meal: "lunch"`), or clears it with \
    `recipe_id: null`, which then counts as an open day. All changes must be in one week. \
    Nothing is saved; use set_dinner or change_day for that.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "changes" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "date" => %{"type" => "string", "format" => "date"},
              "recipe_id" => %{"type" => ["integer", "null"]},
              "meal" => %{"type" => "string", "enum" => ["dinner", "lunch"]},
              "servings" => %{"type" => "integer", "minimum" => 1}
            },
            "required" => ["date", "recipe_id"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["changes"],
      "additionalProperties" => false
    }

  @impl true
  def call(scope, %{"changes" => [_ | _] = changes}) do
    with {:ok, changes} <- parse(changes),
         {:ok, week} <- one_week(changes),
         :ok <- known_recipes(scope, changes) do
      {:ok, plan} = Planning.load_plan(scope, Streams.plan(scope, week))
      changed = Enum.reduce(changes, plan, &change/2)
      rung = Forecast.live(scope)
      now = Budget.status(scope, plan, week, rung)
      then = Budget.status(scope, changed, week, rung)

      {:ok,
       %{
         week_start: week,
         budget: now.budget,
         now: forecast(now),
         then: forecast(then),
         difference: Decimal.sub(then.expected, now.expected)
       }}
    end
  end

  def call(_scope, _args),
    do: {:error, "what_if needs changes: a list of {date, recipe_id or null}."}

  defp parse(changes) do
    Enum.reduce_while(changes, {:ok, []}, fn change, {:ok, acc} ->
      with %{"recipe_id" => id} when is_integer(id) or is_nil(id) <- change,
           {:ok, date} <- Tool.date(change["date"]) do
        servings =
          if is_integer(change["servings"]) and change["servings"] > 0, do: change["servings"]

        key = Streams.slot_key(date, Tool.meal(change))
        {:cont, {:ok, [%{date: date, key: key, recipe_id: id, servings: servings || 4} | acc]}}
      else
        {:error, message} -> {:halt, {:error, message}}
        _ -> {:halt, {:error, "Each change needs recipe_id, a number or null."}}
      end
    end)
    |> case do
      {:ok, changes} -> {:ok, Enum.reverse(changes)}
      error -> error
    end
  end

  defp one_week(changes) do
    case Enum.uniq(for c <- changes, do: Streams.monday(c.date)) do
      [week] -> {:ok, week}
      _ -> {:error, "All changes must be in one week; ask once per week."}
    end
  end

  defp known_recipes(scope, changes) do
    ids = for %{recipe_id: id} <- changes, id != nil, uniq: true, do: id
    found = MapSet.new(Recipes.get_many(scope, ids), & &1.id)

    case Enum.reject(ids, &MapSet.member?(found, &1)) do
      [] -> :ok
      missing -> {:error, "No recipe with id #{Enum.join(missing, ", ")} in this household."}
    end
  end

  defp change(%{key: key, recipe_id: nil}, plan),
    do: %{plan | slots: Map.delete(plan.slots, key)}

  defp change(%{key: key, recipe_id: id, servings: servings}, plan),
    do: %{plan | slots: Map.put(plan.slots, key, %{recipe_id: id, servings: servings})}

  defp forecast(status) do
    %{
      expected: status.expected,
      low: status.low,
      high: status.high,
      risk: status.risk,
      open_days: status.open_days,
      over_budget: status.over
    }
  end
end
