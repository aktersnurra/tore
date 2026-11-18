# A household with six weeks of history, for trying a harness against local Tore.
# Run it on a copy of the dev database, never the one you use:
#
#     TORE_DEV_DB=/path/to/copy.db mix run harness/fixtures/berg.exs
#
# Then run a task for it with harness/fixtures/agent.exs.
#
# What the history holds, for the weekly reflection to find:
# - Thursday dinner is skipped four weeks in six (twice "went out").
# - Salmon on a Tuesday is swapped for pasta every time it's planned.
# - Tacos every Friday.
# - Sunday's meat sauce becomes Monday's leftovers three times.
# - Lentil soup is removed both times it's planned.

import Ecto.Query

alias Tore.{Accounts, EventStore, Household, Planning, Repo, Streams}
alias Tore.Planning.Events

sub = "harness-berg"

if Repo.exists?(from u in Accounts.User, where: u.oidc_sub == ^sub),
  do: raise("#{sub} already exists; seed a fresh copy of the database")

{:ok, household} = Household.create_household(%{name: "Familjen Berg", locale: "sv"})
Repo.insert!(%Accounts.PendingMember{username: "berg", household_id: household.id})

{:ok, user} =
  Accounts.sign_in(%{
    "sub" => sub,
    "preferred_username" => "berg",
    "name" => "Sara Berg",
    "tore_ai" => true
  })

{_user, scope} = Accounts.get_session(user.id)
{:ok, _} = Household.set_ai_sponsor(scope, user, true)

{:ok, _} =
  Household.update_preferences(scope, %{
    allergies: ["nötter"],
    dietary_restrictions: [],
    weekly_budget: Decimal.new(1400)
  })

recipe = fn title, minutes, ingredients ->
  {:ok, recipe} =
    Tore.Recipes.create(
      scope,
      %{
        title: title,
        recipe_type: :meal,
        base_servings: 4,
        prep_time_minutes: 10,
        cook_time_minutes: minutes,
        steps: Jason.encode!(["Förbered.", "Laga.", "Servera."]),
        ingredients:
          for({name, q, unit} <- ingredients, do: %{name: name, quantity: q, unit: unit})
      },
      image: false
    )

  recipe
end

r = %{
  tacos:
    recipe.("Tacos", 20, [{"nötfärs", 500, "g"}, {"tortillas", 8, "st"}, {"tomat", 3, "st"}]),
  lax: recipe.("Ugnsbakad lax med potatis", 30, [{"laxfilé", 500, "g"}, {"potatis", 800, "g"}]),
  carbonara:
    recipe.("Pasta carbonara", 20, [
      {"spaghetti", 500, "g"},
      {"bacon", 140, "g"},
      {"ägg", 3, "st"}
    ]),
  kottfarssas:
    recipe.("Köttfärssås med spaghetti", 40, [
      {"nötfärs", 500, "g"},
      {"krossade tomater", 1, "burk"}
    ]),
  linssoppa: recipe.("Röd linssoppa", 30, [{"röda linser", 300, "g"}, {"kokosmjölk", 1, "burk"}]),
  kyckling: recipe.("Kycklinggryta med ris", 35, [{"kycklingfilé", 600, "g"}, {"ris", 4, "dl"}]),
  pannkakor:
    recipe.("Pannkakor med sylt", 25, [{"mjöl", 2.5, "dl"}, {"mjölk", 6, "dl"}, {"ägg", 3, "st"}]),
  korv:
    recipe.("Korv stroganoff", 25, [{"falukorv", 600, "g"}, {"grädde", 2, "dl"}, {"ris", 4, "dl"}]),
  fiskpinnar:
    recipe.("Fiskpinnar med potatismos", 25, [{"fiskpinnar", 20, "st"}, {"potatis", 800, "g"}]),
  pizza: recipe.("Hemmagjord pizza", 45, [{"vetemjöl", 6, "dl"}, {"mozzarella", 250, "g"}]),
  falafel: recipe.("Falafel i pitabröd", 20, [{"falafel", 16, "st"}, {"pitabröd", 4, "st"}]),
  soppa:
    recipe.("Potatis- och purjolökssoppa", 35, [{"potatis", 600, "g"}, {"purjolök", 2, "st"}])
}

this_monday = Streams.monday(Tore.Clock.today())

# One week of planning events, backdated to the evening of each day they're about.
week = fn weeks_ago, events ->
  monday = Date.add(this_monday, -7 * weeks_ago)
  stream = Streams.plan(scope, monday)
  days = ~w(mon tue wed thu fri sat sun)

  rows =
    for {event, n} <- Enum.with_index(events) do
      day = event.slot_key |> String.split("_") |> hd()
      date = Date.add(monday, Enum.find_index(days, &(&1 == day)))

      %{
        household_id: household.id,
        stream_id: stream,
        stream_type: "planning",
        event_type: event.__struct__ |> Module.split() |> List.last(),
        data: Jason.encode!(Map.from_struct(event)),
        metadata: nil,
        inserted_at: NaiveDateTime.new!(date, Time.new!(17, 0, n))
      }
    end

  Repo.insert_all(EventStore.Event, rows)
end

assign = &%Events.RecipeAssigned{slot_key: &1, recipe_id: &2.id, servings: 4}
remove = &%Events.RecipeRemoved{slot_key: &1}
skip = &%Events.MealSkipped{slot_key: &1, reason: &2}
leftover = &%Events.LeftoverMarked{slot_key: &1}

week.(6, [
  assign.("mon_dinner", r.kyckling),
  assign.("tue_dinner", r.lax),
  remove.("tue_dinner"),
  assign.("tue_dinner", r.carbonara),
  assign.("wed_dinner", r.korv),
  assign.("thu_dinner", r.soppa),
  skip.("thu_dinner", "went out"),
  assign.("fri_dinner", r.tacos),
  assign.("sun_dinner", r.kottfarssas)
])

week.(5, [
  assign.("mon_dinner", r.kottfarssas),
  leftover.("mon_dinner"),
  assign.("tue_dinner", r.fiskpinnar),
  assign.("wed_dinner", r.linssoppa),
  remove.("wed_dinner"),
  assign.("wed_dinner", r.pannkakor),
  assign.("thu_dinner", r.kyckling),
  assign.("fri_dinner", r.tacos),
  assign.("sat_dinner", r.pizza)
])

week.(4, [
  assign.("mon_dinner", r.korv),
  assign.("tue_dinner", r.lax),
  remove.("tue_dinner"),
  assign.("tue_dinner", r.carbonara),
  assign.("thu_dinner", r.falafel),
  skip.("thu_dinner", nil),
  assign.("fri_dinner", r.tacos),
  assign.("sun_dinner", r.kottfarssas)
])

week.(3, [
  assign.("mon_dinner", r.kottfarssas),
  leftover.("mon_dinner"),
  assign.("tue_dinner", r.kyckling),
  assign.("wed_dinner", r.fiskpinnar),
  assign.("thu_dinner", r.soppa),
  skip.("thu_dinner", "went out"),
  assign.("fri_dinner", r.tacos),
  assign.("sat_dinner", r.pizza)
])

week.(2, [
  assign.("mon_dinner", r.pannkakor),
  assign.("tue_dinner", r.lax),
  remove.("tue_dinner"),
  assign.("tue_dinner", r.carbonara),
  assign.("wed_dinner", r.linssoppa),
  remove.("wed_dinner"),
  assign.("wed_dinner", r.korv),
  assign.("thu_dinner", r.falafel),
  assign.("fri_dinner", r.tacos),
  assign.("sun_dinner", r.kottfarssas)
])

week.(1, [
  assign.("mon_dinner", r.kottfarssas),
  leftover.("mon_dinner"),
  assign.("tue_dinner", r.kyckling),
  assign.("wed_dinner", r.fiskpinnar),
  assign.("thu_dinner", r.korv),
  skip.("thu_dinner", nil),
  assign.("fri_dinner", r.tacos),
  assign.("sat_dinner", r.pizza)
])

# This week so far, through the app's own path. Next week is left empty to plan.
plan = Streams.plan(scope, this_monday)
{:ok, _} = Planning.assign_recipe(scope, plan, "mon_dinner", r.korv.id, 4)
{:ok, _} = Planning.assign_recipe(scope, plan, "tue_dinner", r.carbonara.id, 4)
{:ok, _} = Planning.assign_recipe(scope, plan, "fri_dinner", r.tacos.id, 4)

today = Tore.Clock.today()
# The salmon has to go by next Tuesday, so the plan has to decide what to do with it.
{:ok, _} =
  Tore.Pantry.add_item(scope, %{
    name: "laxfilé",
    expires_at: Date.add(Date.beginning_of_week(today), 8)
  })

{:ok, _} = Tore.Pantry.add_item(scope, %{name: "potatis", expires_at: Date.add(today, 14)})
{:ok, _} = Tore.Pantry.add_item(scope, %{name: "ris", expires_at: nil})

IO.puts("Seeded #{household.name} (household #{household.id}), member #{sub}")
