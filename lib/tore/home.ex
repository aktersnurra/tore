defmodule Tore.Home do
  @moduledoc """
  Where the app opens, and the quick swaps above the chat box.

  A decision model picks both (`Tore.Harness.Kinds.HomePick`) from facts worked out here, and
  the stored pick is the latest applied `home_pick_run`. Opening the app reads the stored pick
  and never waits for a new one: a stale pick starts a new run in the background
  (`refresh/1`). Without a pick, or when the model is unsure, a fixed rule (`fallback/1`)
  picks from the same facts.

  The model only chooses among screens and swaps that make sense now (`screens_for/1`,
  `swaps_for/1`), and the stored pick is narrowed the same way when it is read, so a review
  that has since been handled is never the screen the app opens on.

  Times are the server's local clock (`now/0`): set `TZ` to the household's time zone.
  """

  use Gettext, backend: ToreWeb.Gettext

  import Ecto.Query

  alias Tore.{Repo, Scope, Streams}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.HomePick
  alias Tore.Harness.Capsules.WeekPlanCapsule

  @screens [:today, :plan, :shop, :cooking, :review, :costs]
  @swap_keys [
    :open_today,
    :open_plan,
    :open_shop,
    :open_review,
    :plan_next_week,
    :suggest_tonight,
    :build_list
  ]
  @max_swaps 3
  @min_confidence 0.6
  @min_swap_probability 0.5
  @stale_after_seconds 3600
  @refresh_every_seconds 600

  @type screen :: :today | :plan | :shop | :cooking | :review | :costs
  @type swap_key ::
          :open_today
          | :open_plan
          | :open_shop
          | :open_review
          | :plan_next_week
          | :suggest_tonight
          | :build_list
  @type swap :: %{
          key: swap_key(),
          label: String.t(),
          action: {:open, screen()} | {:prompt, String.t()}
        }
  @type facts :: %{
          now: NaiveDateTime.t(),
          tonight: :planned | :eating_out | :empty,
          planned_this_week: non_neg_integer(),
          unplanned_this_week: non_neg_integer(),
          unplanned_next_week: non_neg_integer(),
          list_items: non_neg_integer(),
          items_left: non_neg_integer(),
          reviews: non_neg_integer()
        }
  @type current :: %{screen: screen(), swaps: [swap()], stale?: boolean()}

  @spec screens() :: [screen()]
  def screens, do: @screens

  @spec swap_keys() :: [swap_key()]
  def swap_keys, do: @swap_keys

  @spec max_swaps() :: pos_integer()
  def max_swaps, do: @max_swaps

  @doc "The server's local time. Set `TZ` to the household's time zone."
  @spec now() :: NaiveDateTime.t()
  def now, do: NaiveDateTime.local_now()

  @doc "The path a screen opens at."
  @spec path(screen()) :: String.t()
  def path(:today), do: "/today"
  def path(:plan), do: "/plan"
  def path(:shop), do: "/shop"
  def path(:cooking), do: "/cooking"
  def path(:review), do: "/review"
  def path(:costs), do: "/settings/costs"

  # ----- reading the pick ------------------------------------------------------------------

  @doc """
  The screen the app opens on and the swaps above the chat box: the stored pick, narrowed to
  what makes sense now, or the fixed rule's when there's none. `stale?` says a new pick is due.
  """
  @spec current(Scope.t(), NaiveDateTime.t()) :: current()
  def current(%Scope{} = scope, now \\ now()) do
    facts = facts(scope, now)

    case latest_pick(scope) do
      nil ->
        facts |> fallback() |> resolve(true)

      %KitchenRun{artifacts: [%HomePick{} = pick | _]} = run ->
        pick
        |> narrow(facts)
        |> resolve(stale?(scope, run))
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

  defp narrow(%HomePick{screen: screen, swaps: swaps}, facts) do
    if screen in screens_for(facts) do
      %{
        screen: screen,
        swaps: Enum.filter(swaps, &(&1 in swaps_for(facts) and &1 != open(screen)))
      }
    else
      fallback(facts)
    end
  end

  defp resolve(%{screen: screen, swaps: swaps}, stale?),
    do: %{screen: screen, swaps: Enum.map(swaps, &swap/1), stale?: stale?}

  # ----- facts -----------------------------------------------------------------------------

  @doc """
  What the pick is made from, worked out in code, since a decision model doesn't do date
  maths: tonight's dinner, what's unplanned from today to Sunday and next week, the list and
  the reviews waiting.
  """
  @spec facts(Scope.t(), NaiveDateTime.t()) :: facts()
  def facts(%Scope{} = scope, %NaiveDateTime{} = now) do
    today = NaiveDateTime.to_date(now)
    monday = Streams.monday(today)
    rest_of_week = scope |> week(monday) |> Enum.filter(&(Date.compare(&1.date, today) != :lt))
    next_week = week(scope, Date.add(monday, 7))
    {:ok, list} = Tore.Shop.load_list(scope, Streams.shop_list(scope, monday))
    items = Map.values(list.items)

    %{
      now: now,
      tonight: rest_of_week |> Enum.find(&(&1.date == today)) |> tonight(),
      planned_this_week: Enum.count(rest_of_week, &(&1.status == :assigned)),
      unplanned_this_week: Enum.count(rest_of_week, &(&1.status == :empty)),
      unplanned_next_week: Enum.count(next_week, &(&1.status == :empty)),
      list_items: length(items),
      items_left: Enum.count(items, &(not &1.checked)),
      reviews: length(Runs.list_reviews(scope))
    }
  end

  defp week(scope, monday) do
    ctx = %{
      household_id: scope.household_id,
      plan_stream_id: Streams.plan(scope, monday),
      week_start: monday
    }

    WeekPlanCapsule.build(ctx).slots || []
  end

  defp tonight(%{status: :assigned}), do: :planned
  defp tonight(%{status: :eating_out}), do: :eating_out
  defp tonight(_slot), do: :empty

  @doc "The screens that make sense now: Review only with something waiting, Cooking only with a dinner planned."
  @spec screens_for(facts()) :: [screen()]
  def screens_for(facts) do
    Enum.filter(@screens, fn
      :review -> facts.reviews > 0
      :cooking -> facts.tonight == :planned
      _screen -> true
    end)
  end

  @doc "The swaps that make sense now."
  @spec swaps_for(facts()) :: [swap_key()]
  def swaps_for(facts) do
    Enum.filter(@swap_keys, fn
      :open_review -> facts.reviews > 0
      :plan_next_week -> facts.unplanned_next_week > 0
      :suggest_tonight -> facts.tonight == :empty
      :build_list -> facts.list_items == 0 and facts.planned_this_week > 0
      _always -> true
    end)
  end

  # ----- the fixed rule ----------------------------------------------------------------------

  @doc """
  The pick without a model: a review waiting comes first, then the list on Saturday morning,
  next week's plan on Sunday evening, and otherwise tonight. The swaps open the other main
  screens.
  """
  @spec fallback(facts()) :: %{screen: screen(), swaps: [swap_key()]}
  def fallback(facts) do
    day = Date.day_of_week(facts.now)
    hour = facts.now.hour

    screen =
      cond do
        facts.reviews > 0 -> :review
        day == 6 and hour < 14 -> :shop
        day == 7 and hour >= 16 -> :plan
        true -> :today
      end

    swaps =
      [:open_today, :open_plan, :open_shop, :open_review]
      |> Enum.filter(&(&1 in swaps_for(facts) and &1 != open(screen)))
      |> Enum.take(@max_swaps)

    %{screen: screen, swaps: swaps}
  end

  @doc "The fixed rule's pick, as the run stores it."
  @spec fallback_pick(facts()) :: HomePick.t()
  def fallback_pick(facts) do
    %{screen: screen, swaps: swaps} = fallback(facts)
    %HomePick{screen: screen, source: :rules, swaps: swaps}
  end

  # ----- the decision model's question -----------------------------------------------------

  @doc "The facts and the household's context as `state` lines for the decision model."
  @spec state(Scope.t(), facts()) :: [String.t()]
  def state(%Scope{} = scope, facts) do
    monday = Streams.monday(NaiveDateTime.to_date(facts.now))

    plan =
      WeekPlanCapsule.to_prompt(
        WeekPlanCapsule.build(%{
          household_id: scope.household_id,
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
      "#{facts.reviews} things wait for the household to review.",
      plan,
      Tore.Household.Memory.snapshot(scope)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp tonight_line(:planned), do: "Tonight's dinner is planned."
  defp tonight_line(:eating_out), do: "The household eats out tonight."
  defp tonight_line(:empty), do: "Nothing is planned for dinner tonight."

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

      %HomePick{screen: screen, source: :model, swaps: swaps}
    else
      _unsure -> fallback_pick(facts)
    end
  end

  defp screen_criterion(:today), do: "Tonight's dinner, and starting to cook it."
  defp screen_criterion(:plan), do: "This week's or next week's dinners, to plan or change them."
  defp screen_criterion(:shop), do: "The shopping list, to buy groceries."
  defp screen_criterion(:cooking), do: "Cooking tonight's recipe step by step."

  defp screen_criterion(:review),
    do:
      "Something Tore read, such as a recipe or a receipt, waiting for the household to check it."

  defp screen_criterion(:costs), do: "What the household has spent on food this month."

  defp swap_criterion(:open_today), do: "The household wants to see tonight's dinner."

  defp swap_criterion(:open_plan),
    do: "The household wants to look at or change this week's plan."

  defp swap_criterion(:open_shop), do: "The household is shopping, or about to."
  defp swap_criterion(:open_review), do: "Something waits for the household to review it."
  defp swap_criterion(:plan_next_week), do: "Next week's dinners need planning now."
  defp swap_criterion(:suggest_tonight), do: "The household needs an idea for dinner tonight."

  defp swap_criterion(:build_list),
    do: "The household wants a shopping list made from this week's plan."

  # ----- swaps -------------------------------------------------------------------------------

  @max_label 24
  @max_prompt 200

  @doc "Where a Capture turn's swaps go for one person's chat bar, as `{:quick_swaps, [swap]}`."
  @spec swaps_topic(integer()) :: String.t()
  def swaps_topic(user_id), do: "chat_bar:user:#{user_id}"

  @doc """
  Swaps a Capture turn suggests, from the chat model's `quick_swaps` call: at most three, each a
  short label that opens a screen in the list or sends one line to Capture. An error says why,
  for the model to correct.
  """
  @spec suggested_swaps(term()) :: {:ok, [swap()]} | {:error, String.t()}
  def suggested_swaps(raw) when is_list(raw) and length(raw) <= @max_swaps do
    Enum.reduce_while(raw, {:ok, []}, fn item, {:ok, acc} ->
      case suggested_swap(item) do
        {:ok, swap} -> {:cont, {:ok, acc ++ [swap]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def suggested_swaps(raw) when is_list(raw), do: {:error, "send at most #{@max_swaps} swaps"}
  def suggested_swaps(_raw), do: {:error, "swaps must be a list"}

  defp suggested_swap(%{"label" => label} = item) when is_binary(label) do
    label = String.trim(label)

    cond do
      label == "" or String.length(label) > @max_label ->
        {:error, "each label must be 1 to #{@max_label} characters"}

      Map.has_key?(item, "screen") == Map.has_key?(item, "prompt") ->
        {:error, "each swap needs either a screen or a prompt, not both"}

      Map.has_key?(item, "screen") ->
        case Enum.find(@screens, &(Atom.to_string(&1) == item["screen"])) do
          nil -> {:error, "screen must be one of #{Enum.join(@screens, ", ")}"}
          screen -> {:ok, %{label: label, action: {:open, screen}}}
        end

      true ->
        prompt = if is_binary(item["prompt"]), do: String.trim(item["prompt"]), else: ""

        if prompt == "" or prompt =~ "\n" or String.length(prompt) > @max_prompt,
          do: {:error, "each prompt must be one line of at most #{@max_prompt} characters"},
          else: {:ok, %{label: label, action: {:prompt, prompt}}}
    end
  end

  defp suggested_swap(_item), do: {:error, "each swap needs a label"}

  @doc "A swap's label and what tapping it does, in the current locale."
  @spec swap(swap_key()) :: swap()
  def swap(:open_today), do: open_swap(:open_today, gettext("Tonight"), :today)
  def swap(:open_plan), do: open_swap(:open_plan, gettext("This week's plan"), :plan)
  def swap(:open_shop), do: open_swap(:open_shop, gettext("Shopping list"), :shop)
  def swap(:open_review), do: open_swap(:open_review, gettext("Review"), :review)

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
