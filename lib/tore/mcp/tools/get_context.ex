defmodule Tore.Mcp.Tools.GetContext do
  @moduledoc """
  What Claude needs to know about the household before it does anything: the language everything
  is written in, today, diet and allergies, the memory, this week's and next week's dinners, the
  shopping list, the pantry, and what's due. The same facts Capture's prompt is built from.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.{Household, Pantry, Shop, Streams}
  alias Tore.Harness.Capsules.{PantryBeliefsCapsule, WeekPlanCapsule}
  alias Tore.Pantry.PantryItem

  @impl true
  def name, do: "get_context"

  @impl true
  def description,
    do: """
    Start here. The household's language (write every name, recipe and memory entry in it), \
    today's date, diet and allergies (hard limits), what the household has told Tore (memory), \
    this week's and next week's dinners by date (with a planned `lunch`, and `lunch_day` on \
    weekends, holidays and `day_off` days, where a lunch could be offered), each week's budget against its estimate in \
    kronor (`priced` of `total` ingredients have a real price, the rest are guesses), the basics \
    added to every list, the shopping list, the pantry with best-before dates (approximate), and \
    what's due.\
    """

  @impl true
  def schema, do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def call(scope, _args) do
    today = Tore.Clock.today()
    monday = Streams.monday(today)
    next_monday = Date.add(monday, 7)
    next_week = week(scope, next_monday)
    pantry = PantryBeliefsCapsule.build(%{scope: scope})

    {:ok,
     %{
       language: Household.locale(scope),
       today: today,
       weekday: Calendar.strftime(today, "%A"),
       diet: scope |> Household.get_preferences() |> Household.prefs_to_dietary_guidance(),
       memory: Household.Memory.snapshot(scope),
       this_week: week(scope, monday),
       next_week: next_week,
       budget: %{this_week: budget(scope, monday), next_week: budget(scope, next_monday)},
       basics: Enum.map(Tore.Basics.list(scope), & &1.name),
       shopping_list: shopping_list(scope, monday),
       pantry: pantry(scope, today),
       due: due(next_week, pantry)
     }}
  end

  defp week(scope, monday) do
    %WeekPlanCapsule{slots: slots} =
      WeekPlanCapsule.build(%{
        scope: scope,
        plan_stream_id: Streams.plan(scope, monday),
        week_start: monday
      })

    slots || empty_week(monday)
  end

  defp empty_week(monday) do
    for i <- 0..6 do
      date = Date.add(monday, i)
      key = (date |> Calendar.strftime("%a") |> String.downcase()) <> "_dinner"

      %{
        date: date,
        slot_key: key,
        status: :empty,
        recipe_id: nil,
        recipe_title: nil,
        servings: nil,
        pinned: false,
        lunch: nil,
        lunch_day: Tore.Planning.State.lunch_day?(%Tore.Planning.State{}, date),
        day_off: false
      }
    end
  end

  defp budget(scope, monday) do
    status = Tore.Budget.status(scope, monday)

    %{
      budget: status.budget,
      expected: status.expected,
      over: status.over,
      priced: status.estimate.priced,
      total: status.estimate.total
    }
  end

  defp shopping_list(scope, monday) do
    {:ok, state} = Shop.load_list(scope, Streams.shop_list(scope, monday))

    state.items
    |> Map.values()
    |> Enum.sort_by(&{&1.checked, &1.name})
    |> Enum.map(&Map.take(&1, [:id, :name, :quantity, :unit, :section, :checked, :basic]))
  end

  defp pantry(scope, today) do
    now = DateTime.utc_now()

    for item <- Pantry.list_inventory(scope) do
      %{
        name: item.name,
        quantity: item.quantity,
        unit: item.unit,
        belief: PantryItem.effective_belief(item, now, today),
        expires_on: item.expires_at
      }
    end
  end

  defp due(next_week, %PantryBeliefsCapsule{use_soon: use_soon}) do
    unplanned =
      if Enum.all?(next_week, &(&1.status == :empty)),
        do: ["next week has no dinners planned"],
        else: []

    soon = if use_soon == [], do: [], else: ["use soon: " <> Enum.join(use_soon, ", ")]
    unplanned ++ soon
  end
end
