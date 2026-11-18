defmodule Tore.Home do
  @moduledoc """
  Where the app opens, the quick swaps above the chat box, and the one note Today may show.

  A decision model picks both (`Tore.Harness.Kinds.HomePick`) from facts worked out here, and
  the stored pick is the latest applied `home_pick_run`. Opening the app reads the stored pick
  and never waits for a new one: a stale pick starts a new run in the background
  (`refresh/1`). Without a pick, or when the model is unsure, a fixed rule (`fallback/1`)
  picks from the same facts.

  The model only chooses among screens, swaps and notes that make sense now (`screens_for/1`,
  `swaps_for/1`, `notes_for/1`), and the stored pick is narrowed the same way when it is read.
  A note is code's own sentence (Today writes it from the facts); the model only picks which
  one, if any, is worth saying at this hour, for this household.

  Times are the household's clock (`Tore.Clock`).
  """

  use Gettext, backend: ToreWeb.Gettext

  import Ecto.Query

  alias Tore.{Repo, Scope, Streams}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.HomePick
  alias Tore.Harness.Capsules.WeekPlanCapsule

  @screens [:today, :plan, :shop]
  @swap_keys [
    :open_today,
    :open_plan,
    :open_shop,
    :plan_next_week,
    :suggest_tonight,
    :build_list
  ]
  @note_keys [:buy_for_tomorrow, :shop_now, :tomorrow_open]
  @max_swaps 3
  @min_confidence 0.6
  @min_swap_probability 0.5
  @stale_after_seconds 3600
  @refresh_every_seconds 600

  @type screen :: :today | :plan | :shop
  @type swap_key ::
          :open_today
          | :open_plan
          | :open_shop
          | :plan_next_week
          | :suggest_tonight
          | :build_list
  @type swap :: %{
          key: swap_key(),
          label: String.t(),
          action: {:open, screen()} | {:prompt, String.t()}
        }
  @type note_key :: :buy_for_tomorrow | :shop_now | :tomorrow_open
  @type facts :: %{
          now: NaiveDateTime.t(),
          tonight: :planned | :eating_out | :empty,
          planned_this_week: non_neg_integer(),
          unplanned_this_week: non_neg_integer(),
          unplanned_next_week: non_neg_integer(),
          list_items: non_neg_integer(),
          items_left: non_neg_integer(),
          tomorrow: :planned | :eating_out | :empty,
          tomorrow_missing: [String.t()]
        }
  @type note :: %{key: note_key(), things: [String.t()], count: non_neg_integer()}
  @type current :: %{
          screen: screen(),
          swaps: [swap()],
          note: note() | nil,
          stale?: boolean()
        }

  @spec screens() :: [screen()]
  def screens, do: @screens

  @spec swap_keys() :: [swap_key()]
  def swap_keys, do: @swap_keys

  @spec note_keys() :: [note_key()]
  def note_keys, do: @note_keys

  @spec max_swaps() :: pos_integer()
  def max_swaps, do: @max_swaps

  @doc "The path a screen opens at."
  @spec path(screen()) :: String.t()
  def path(:today), do: "/today"
  def path(:plan), do: "/plan"
  def path(:shop), do: "/shop"

  # ----- reading the pick ------------------------------------------------------------------

  @doc """
  The screen the app opens on and the swaps above the chat box: the stored pick, narrowed to
  what makes sense now, or the fixed rule's when there's none, when the stored one was the rule's
  too, or when the household can't use the model now (a stored pick would never be replaced).
  `stale?` says a new pick is due.
  """
  @spec current(Scope.t(), NaiveDateTime.t()) :: current()
  def current(%Scope{} = scope, now \\ Tore.Clock.now()) do
    facts = facts(scope, now)

    case Tore.LLM.check(scope) == :ok and latest_pick(scope) do
      false ->
        facts |> fallback() |> resolve(false, facts)

      nil ->
        facts |> fallback() |> resolve(true, facts)

      # The rule's pick is free to work out again, so it follows the clock and the week.
      %KitchenRun{artifacts: [%HomePick{source: :rules} | _]} = run ->
        facts |> fallback() |> resolve(stale?(scope, run), facts)

      %KitchenRun{artifacts: [%HomePick{} = pick | _]} = run ->
        pick
        |> narrow(facts)
        |> resolve(stale?(scope, run), facts)
    end
  end

  @doc """
  Starts a new pick in the background when the household may use the decision model and no
  pick was started in the last ten minutes. The result arrives as `{:run_changed, run}`.
  """
  @spec refresh(Scope.t()) :: :started | :skipped
  def refresh(%Scope{} = scope) do
    if Tore.LLM.check(scope) == :ok and not started_recently?(scope) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Tore.TaskSupervisor, fn ->
          Runs.start(scope, Tore.Harness.Kinds.HomePick, %{})
        end)

      :started
    else
      :skipped
    end
  end

  defp latest_pick(scope) do
    from(r in KitchenRun,
      where: r.kind == "home_pick_run" and r.status == :applied,
      order_by: [desc: r.applied_at],
      limit: 1
    )
    |> Repo.one(Scope.repo_opts(scope))
  end

  # Stale when older than an hour, or when any other run changed something since.
  defp stale?(scope, %KitchenRun{applied_at: at}) do
    DateTime.diff(DateTime.utc_now(), at) > @stale_after_seconds or
      from(r in KitchenRun,
        where: r.kind != "home_pick_run" and r.status == :applied and r.applied_at > ^at
      )
      |> Repo.exists?(Scope.repo_opts(scope))
  end

  defp started_recently?(scope) do
    since = DateTime.add(DateTime.utc_now(), -@refresh_every_seconds)

    from(r in KitchenRun, where: r.kind == "home_pick_run" and r.opened_at > ^since)
    |> Repo.exists?(Scope.repo_opts(scope))
  end

  defp narrow(%HomePick{screen: screen, swaps: swaps, note: note}, facts) do
    if screen in screens_for(facts) do
      %{
        screen: screen,
        swaps: Enum.filter(swaps, &(&1 in swaps_for(facts) and &1 != open(screen))),
        note: if(note in notes_for(facts), do: note)
      }
    else
      fallback(facts)
    end
  end

  defp resolve(%{screen: screen, swaps: swaps, note: note}, stale?, facts) do
    %{
      screen: screen,
      swaps: Enum.map(swaps, &swap/1),
      note: note && %{key: note, things: facts.tomorrow_missing, count: facts.items_left},
      stale?: stale?
    }
  end

  # ----- facts -----------------------------------------------------------------------------

  @doc """
  What the pick is made from, worked out in code, since a decision model doesn't do date
  maths: tonight's dinner, what's unplanned from today to Sunday and next week, the list, and
  tomorrow's dinner with what it needs that's neither at home nor on a list.
  """
  @spec facts(Scope.t(), NaiveDateTime.t()) :: facts()
  def facts(%Scope{} = scope, %NaiveDateTime{} = now) do
    today = NaiveDateTime.to_date(now)
    monday = Streams.monday(today)
    rest_of_week = scope |> week(monday) |> Enum.filter(&(Date.compare(&1.date, today) != :lt))
    next_week = week(scope, Date.add(monday, 7))
    {:ok, list} = Tore.Shop.load_list(scope, Streams.shop_list(scope, monday))
    items = Map.values(list.items)
    tomorrow = Date.add(today, 1)
    tomorrow_slot = Enum.find(rest_of_week ++ next_week, &(&1.date == tomorrow))

    %{
      now: now,
      tonight: rest_of_week |> Enum.find(&(&1.date == today)) |> tonight_status(),
      planned_this_week: Enum.count(rest_of_week, &(&1.status == :assigned)),
      unplanned_this_week: Enum.count(rest_of_week, &(&1.status == :empty)),
      unplanned_next_week: Enum.count(next_week, &(&1.status == :empty)),
      list_items: length(items),
      items_left: Enum.count(items, &(not &1.checked)),
      tomorrow: tonight_status(tomorrow_slot),
      tomorrow_missing: missing_for(scope, tomorrow_slot, items)
    }
  end

  # What tomorrow's dish needs that isn't at home, and isn't on this week's or its week's list.
  defp missing_for(scope, %{status: :assigned, recipe_id: id, date: date}, items)
       when is_integer(id) do
    case Tore.Recipes.get_many(scope, [id]) do
      [recipe] ->
        names = Enum.map(recipe.recipe_ingredients, & &1.ingredient.name)

        {:ok, its_list} =
          Tore.Shop.load_list(scope, Streams.shop_list(scope, Streams.monday(date)))

        listed =
          MapSet.new(
            items ++ Map.values(its_list.items),
            &Tore.Recipes.Ingredient.to_key(&1.name)
          )

        scope
        |> Tore.Pantry.at_home(names)
        |> Map.fetch!(:missing)
        |> Enum.reject(&(Tore.Recipes.Ingredient.to_key(&1) in listed))

      [] ->
        []
    end
  end

  defp missing_for(_scope, _slot, _items), do: []

  defp week(scope, monday) do
    ctx = %{
      scope: scope,
      plan_stream_id: Streams.plan(scope, monday),
      week_start: monday
    }

    WeekPlanCapsule.build(ctx).slots || []
  end

  defp tonight_status(%{status: :assigned}), do: :planned
  defp tonight_status(%{status: :eating_out}), do: :eating_out
  defp tonight_status(_slot), do: :empty

  @doc "The screens that make sense now: all of them."
  @spec screens_for(facts()) :: [screen()]
  def screens_for(_facts), do: @screens

  @doc "The swaps that make sense now."
  @spec swaps_for(facts()) :: [swap_key()]
  def swaps_for(facts) do
    Enum.filter(@swap_keys, fn
      :plan_next_week -> facts.unplanned_next_week > 0
      :suggest_tonight -> facts.tonight == :empty
      :build_list -> facts.list_items == 0 and facts.planned_this_week > 0
      _always -> true
    end)
  end

  @doc "The notes that are true now: each says something the household could act on."
  @spec notes_for(facts()) :: [note_key()]
  def notes_for(facts) do
    Enum.filter(@note_keys, fn
      :buy_for_tomorrow -> facts.tomorrow_missing != []
      :shop_now -> facts.items_left > 0
      :tomorrow_open -> facts.tomorrow == :empty
    end)
  end

  # ----- the fixed rule ----------------------------------------------------------------------

  @doc """
  The pick without a model: the list on Saturday morning,
  next week's plan on Sunday evening, and otherwise tonight. The swaps open the other main
  screens. The note: what tomorrow needs from the afternoon, the list on Saturday morning, an
  open tomorrow in the evening.
  """
  @spec fallback(facts()) :: %{screen: screen(), swaps: [swap_key()], note: note_key() | nil}
  def fallback(facts) do
    day = Date.day_of_week(facts.now)
    hour = facts.now.hour

    screen =
      cond do
        day == 6 and hour < 14 -> :shop
        day == 7 and hour >= 16 -> :plan
        true -> :today
      end

    swaps =
      [:open_today, :open_plan, :open_shop]
      |> Enum.filter(&(&1 in swaps_for(facts) and &1 != open(screen)))
      |> Enum.take(@max_swaps)

    %{screen: screen, swaps: swaps, note: fallback_note(facts, day, hour)}
  end

  defp fallback_note(facts, day, hour) do
    notes = notes_for(facts)

    cond do
      :buy_for_tomorrow in notes and hour >= 14 -> :buy_for_tomorrow
      :shop_now in notes and day == 6 and hour < 14 -> :shop_now
      :tomorrow_open in notes and hour >= 17 -> :tomorrow_open
      true -> nil
    end
  end

  @doc "The fixed rule's pick, as the run stores it."
  @spec fallback_pick(facts()) :: HomePick.t()
  def fallback_pick(facts) do
    %{screen: screen, swaps: swaps, note: note} = fallback(facts)
    %HomePick{screen: screen, source: :rules, swaps: swaps, note: note}
  end

  # ----- the decision model's question -----------------------------------------------------

  @doc "The facts and the household's context as `state` lines for the decision model."
  @spec state(Scope.t(), facts()) :: [String.t()]
  def state(%Scope{} = scope, facts) do
    monday = Streams.monday(NaiveDateTime.to_date(facts.now))

    plan =
      WeekPlanCapsule.to_prompt(
        WeekPlanCapsule.build(%{
          scope: scope,
          plan_stream_id: Streams.plan(scope, monday),
          week_start: monday
        })
      )

    [
      "It is #{Calendar.strftime(facts.now, "%A %Y-%m-%d, %H:%M")}.",
      tonight_line(facts.tonight),
      "#{facts.unplanned_this_week} dinners from today to Sunday are unplanned.",
      "#{facts.unplanned_next_week} of next week's 7 dinners are unplanned.",
      "The shopping list has #{facts.list_items} items, #{facts.items_left} not yet bought.",
      tomorrow_line(facts),
      trips_line(scope),
      plan,
      Tore.Household.Memory.snapshot(scope)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp tonight_line(:planned), do: "Tonight's dinner is planned."
  defp tonight_line(:eating_out), do: "The household eats out tonight."
  defp tonight_line(:empty), do: "Nothing is planned for dinner tonight."

  defp tomorrow_line(%{tomorrow: :empty}), do: "Nothing is planned for dinner tomorrow."
  defp tomorrow_line(%{tomorrow: :eating_out}), do: "The household eats out tomorrow."

  defp tomorrow_line(%{tomorrow_missing: []}),
    do: "Tomorrow's dinner is planned, and all of it is at home or on the list."

  defp tomorrow_line(%{tomorrow_missing: missing}),
    do: "Tomorrow's dinner needs #{Enum.join(missing, ", ")}: not at home and not on the list."

  # When they shop, so a note about the list lands when they usually go.
  defp trips_line(scope) do
    case Tore.Shop.Walk.trip_starts(scope) do
      [] ->
        nil

      starts ->
        times =
          Enum.map_join(starts, ", ", &Calendar.strftime(Tore.Clock.local(&1), "%A %H:%M"))

        "Their latest shopping trips began: #{times}."
    end
  end

  @doc """
  One `choice` for the screen, among those that make sense now, and one `noul` per swap that
  makes sense now.
  """
  @spec questions(facts()) :: map()
  def questions(facts) do
    screen = %{
      "type" => "choice",
      "instructions" =>
        "A household opens its kitchen app. Which screen helps them most right now?",
      "criteria" => Map.new(screens_for(facts), &{Atom.to_string(&1), screen_criterion(&1)})
    }

    facts
    |> swaps_for()
    |> Map.new(&{"swap_#{&1}", %{"type" => "noul", "instructions" => swap_criterion(&1)}})
    |> Map.put("screen", screen)
    |> put_note_question(notes_for(facts))
  end

  defp put_note_question(questions, []), do: questions

  defp put_note_question(questions, notes) do
    Map.put(questions, "note", %{
      "type" => "choice",
      "instructions" =>
        "Today, the dinner screen, can show the household one short note. Which helps most " <>
          "right now, at this hour, given their habits? Choose none unless it's worth a glance.",
      "criteria" =>
        Map.new(notes, &{Atom.to_string(&1), note_criterion(&1)})
        |> Map.put("none", "Nothing needs saying now.")
    })
  end

  defp note_criterion(:buy_for_tomorrow),
    do:
      "Tomorrow's dinner needs things that aren't at home or on the list, and there's still time to get them."

  defp note_criterion(:shop_now),
    do: "There are things on the list, and this is when they usually shop."

  defp note_criterion(:tomorrow_open),
    do: "Tomorrow's dinner isn't planned, and it's late enough that it should be."

  defp model_note(answers, facts) do
    with %{"choice" => choice, "confidence" => confidence} when is_number(confidence) <-
           answers["note"],
         true <- confidence >= @min_confidence do
      Enum.find(notes_for(facts), &(Atom.to_string(&1) == choice))
    else
      _unsure -> nil
    end
  end

  @doc """
  The pick from the model's answers: its screen when it is sure enough, with the swaps it
  thinks likely, best first. Unsure, it is the fixed rule's pick.
  """
  @spec pick(map(), facts()) :: HomePick.t()
  def pick(answers, facts) do
    with %{"choice" => choice, "confidence" => confidence} when is_number(confidence) <-
           answers["screen"],
         true <- confidence >= @min_confidence,
         screen when not is_nil(screen) <-
           Enum.find(screens_for(facts), &(Atom.to_string(&1) == choice)) do
      swaps =
        facts
        |> swaps_for()
        |> Enum.map(&{&1, get_in(answers, ["swap_#{&1}", "noul"])})
        |> Enum.filter(fn {key, p} ->
          is_number(p) and p >= @min_swap_probability and key != open(screen)
        end)
        |> Enum.sort_by(fn {_key, p} -> p end, :desc)
        |> Enum.map(fn {key, _p} -> key end)
        |> Enum.take(@max_swaps)

      %HomePick{screen: screen, source: :model, swaps: swaps, note: model_note(answers, facts)}
    else
      _unsure -> fallback_pick(facts)
    end
  end

  defp screen_criterion(:today), do: "Tonight's dinner, and starting to cook it."
  defp screen_criterion(:plan), do: "This week's or next week's dinners, to plan or change them."

  defp screen_criterion(:shop),
    do: "The shopping list, to buy groceries, and what was spent on food this month."

  defp swap_criterion(:open_today), do: "The household wants to see tonight's dinner."

  defp swap_criterion(:open_plan),
    do: "The household wants to look at or change this week's plan."

  defp swap_criterion(:open_shop), do: "The household is shopping, or about to."
  defp swap_criterion(:plan_next_week), do: "Next week's dinners need planning now."
  defp swap_criterion(:suggest_tonight), do: "The household needs an idea for dinner tonight."

  defp swap_criterion(:build_list),
    do: "The household wants a shopping list made from this week's plan."

  # ----- swaps -------------------------------------------------------------------------------

  @doc "A swap's label and what tapping it does, in the current locale."
  @spec swap(swap_key()) :: swap()
  def swap(:open_today), do: open_swap(:open_today, gettext("Tonight"), :today)
  def swap(:open_plan), do: open_swap(:open_plan, gettext("This week's plan"), :plan)
  def swap(:open_shop), do: open_swap(:open_shop, gettext("Shopping list"), :shop)

  def swap(:plan_next_week),
    do: prompt_swap(:plan_next_week, gettext("Plan next week"), gettext("Plan next week"))

  def swap(:suggest_tonight) do
    text = gettext("What should we have for dinner tonight?")
    prompt_swap(:suggest_tonight, gettext("Dinner tonight?"), text)
  end

  def swap(:build_list),
    do:
      prompt_swap(
        :build_list,
        gettext("Make the list"),
        gettext("Make the shopping list from this week's plan")
      )

  defp open_swap(key, label, screen), do: %{key: key, label: label, action: {:open, screen}}
  defp prompt_swap(key, label, text), do: %{key: key, label: label, action: {:prompt, text}}

  defp open(screen), do: :"open_#{screen}"
end
