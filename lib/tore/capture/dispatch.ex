defmodule Tore.Capture.Dispatch do
  @moduledoc """
  Handlers invoked by `Tore.Capture.Router` when the model emits a tool call.

  Each function corresponds 1:1 to a tool in the catalogue and produces a
  rendered assistant bubble (a plain map the LiveView already renders).
  `read_receipt/2` is the exception: the same receipt reading for a page outside the chat.
  """

  use Gettext, backend: ToreWeb.Gettext

  alias Tore.Capture.Uploads
  alias Tore.Costs
  alias Tore.Harness.Artifact.{CostEntry, MemoryBatch, PantryBeliefUpdate}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Kinds
  alias Tore.Household.Memory
  alias Tore.Pantry
  alias Tore.Planning
  alias Tore.Recipes
  alias Tore.Shop
  alias Tore.Streams

  @days ~w(mon tue wed thu fri sat sun)
  @default_servings 4
  @suggestion_limit 4

  @type ctx :: %{required(:scope) => Tore.Scope.t(), optional(:actor) => :mcp}
  @type bubble :: map()

  # ── receipt ────────────────────────────────────────────────────────────

  @type receipt_result ::
          {:saved, run_id :: String.t(), text :: String.t()}
          | {:duplicate, text :: String.t()}
          | {:failed, text :: String.t()}

  @doc """
  Reads a receipt photo and says what came of it, with the words to show for it. For a caller
  that is not the chat, such as the shopping list; `ingest_receipt/2` is the same as a chat bubble.
  """
  @spec read_receipt(Tore.Scope.t(), binary()) :: receipt_result()
  def read_receipt(%Tore.Scope{} = scope, image) when is_binary(image) do
    result =
      with_dedup(image, scope, "receipt", fn ->
        case Runs.start(scope, Kinds.Receipt, %{image_binary: image}) do
          {:ok, %KitchenRun{status: :applied} = run} ->
            {:ok, {:saved, run.id, receipt_text(run)}}

          {:ok, %KitchenRun{status: :failed, failure_code: code}} ->
            {:failed, {:failed, error_text(:receipt, code)}}

          {:error, reason} ->
            {:failed, {:failed, error_text(:receipt, reason)}}
        end
      end)

    with :duplicate <- result, do: {:duplicate, duplicate_text()}
  end

  @spec ingest_receipt(binary(), ctx()) :: bubble()
  def ingest_receipt(image, ctx) when is_binary(image) do
    case read_receipt(ctx.scope, image) do
      {:saved, id, text} -> %{role: :assistant, text: text, run_stream_id: id}
      {:duplicate, text} -> %{role: :assistant, text: text}
      {:failed, text} -> %{role: :assistant, error: true, text: text}
    end
  end

  defp receipt_text(%KitchenRun{artifacts: [%CostEntry{} = cost]}) do
    gettext("Saved the receipt from %{store}: %{total} kr.",
      store: cost.store_name,
      total: Decimal.to_string(Decimal.round(cost.total, 2), :normal)
    )
  end

  # ── shelf → pantry update ──────────────────────────────────────────────

  @spec update_pantry_from_shelf(binary(), ctx()) :: bubble()
  def update_pantry_from_shelf(image, ctx) when is_binary(image) do
    result =
      with_dedup(image, ctx.scope, "shelf", fn ->
        case Runs.start(ctx.scope, Kinds.PantryUpdate, %{
               channel: :shelf_photo,
               image_binary: image
             }) do
          {:ok, %KitchenRun{status: :applied} = run} ->
            {:ok, shelf_bubble(run)}

          {:ok, %KitchenRun{status: :failed, failure_code: code}} ->
            {:failed, error_bubble(:pantry, code)}

          {:error, reason} ->
            {:failed, error_bubble(:pantry, reason)}
        end
      end)

    with :duplicate <- result, do: %{role: :assistant, text: duplicate_text()}
  end

  defp shelf_bubble(%KitchenRun{id: sid, artifacts: artifacts}) do
    %PantryBeliefUpdate{items: items} = Enum.find(artifacts, &match?(%PantryBeliefUpdate{}, &1))

    case items do
      [] ->
        %{role: :assistant, text: gettext("I couldn't see any pantry items in that photo.")}

      items ->
        names = items |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.join(", ")

        %{
          role: :assistant,
          text: gettext("Added %{names} from your photo.", names: names),
          run_stream_id: sid
        }
    end
  end

  # ── recipe (grouped: multi-page recipes stay together) ─────────────────

  @spec ingest_recipe([binary()], ctx()) :: bubble()
  def ingest_recipe(images, ctx) when is_list(images) and images != [] do
    case Runs.start(ctx.scope, Kinds.RecipeIngestion, %{images: images}) do
      {:error, {:step_failed, reason}} ->
        refusal_bubble(reason) || error_bubble(:recipe, reason)

      result ->
        recipe_bubble(result)
    end
  end

  # A recipe read from photos or a page is saved straight away; undo deletes it.
  defp recipe_bubble({:ok, %KitchenRun{status: :applied, id: id, artifacts: [proposal]}}) do
    %{
      role: :assistant,
      run_stream_id: id,
      text: gettext("Saved %{title} to your recipes.", title: proposal.title)
    }
  end

  defp recipe_bubble({:ok, %KitchenRun{failure_code: :near_duplicate}}),
    do: %{
      role: :assistant,
      error: true,
      text: gettext("That looks like a recipe you already have.")
    }

  defp recipe_bubble({:ok, %KitchenRun{failure_code: code}}) do
    require Logger
    Logger.info("Capture recipe ingestion failed its check: #{inspect(code)}")
    %{role: :assistant, error: true, text: gettext("I couldn't read a whole recipe from that.")}
  end

  defp recipe_bubble({:error, reason}), do: error_bubble(:recipe, reason)

  defp refusal_bubble(reason) do
    case Tore.LLM.refusal_text(reason) do
      nil -> nil
      text -> %{role: :assistant, text: text}
    end
  end

  # ── fridge → suggestions ───────────────────────────────────────────────

  @spec suggest_from_fridge(binary(), ctx()) :: bubble()
  def suggest_from_fridge(image, ctx) when is_binary(image) do
    case Tore.Pantry.parse_image(ctx.scope, image) do
      {:ok, items} ->
        names = items |> Enum.map(&(&1[:name] || &1["name"])) |> Enum.take(5) |> Enum.join(", ")

        text =
          if names == "" do
            gettext("I can see your fridge but it looks empty.")
          else
            gettext("I can see %{names} in your fridge. Want me to suggest some recipes?",
              names: names
            )
          end

        %{role: :assistant, text: text}

      {:error, reason} ->
        error_bubble(:fridge, reason)
    end
  end

  # ── URL import ─────────────────────────────────────────────────────────

  @spec import_recipe_from_url(String.t(), ctx()) :: bubble()
  def import_recipe_from_url(url, ctx) when is_binary(url) do
    case Runs.start(ctx.scope, Kinds.RecipeIngestion, %{url: url}) do
      {:error, {:step_failed, :not_a_recipe}} ->
        %{role: :assistant, text: gettext("That page doesn't look like a recipe.")}

      {:error, {:step_failed, :timeout}} ->
        %{role: :assistant, text: gettext("The site didn't respond. Try again in a moment.")}

      {:error, {:step_failed, reason}} ->
        refusal_bubble(reason) ||
          %{role: :assistant, text: gettext("Couldn't import that URL.")}

      result ->
        recipe_bubble(result)
    end
  end

  # ── recipe search ──────────────────────────────────────────────────────

  @spec find_recipe(String.t(), ctx()) :: bubble()
  def find_recipe(query, ctx) when is_binary(query) do
    case Recipes.search(ctx.scope, query) do
      [] ->
        %{
          role: :assistant,
          text:
            gettext(
              "I couldn't find a recipe matching \"%{q}\". Want me to import one from a URL?",
              q: query
            )
        }

      [top | rest] ->
        candidates = Enum.take(rest, 2)
        titles = Enum.map_join([top | candidates], ", ", & &1.title)

        %{
          role: :assistant,
          recipe_search: true,
          top_recipe_id: top.id,
          top_title: top.title,
          candidate_ids: Enum.map(candidates, & &1.id),
          text: gettext("I found: %{titles}.", titles: titles)
        }
    end
  end

  # ── plan slot mutation ─────────────────────────────────────────────────

  @doc """
  Puts a recipe on a day's dinner, or its lunch, through a run, so a pinned day stays as it is.
  """
  @spec set_plan_slot(Date.t(), integer(), integer() | nil, ctx(), Streams.meal()) :: bubble()
  def set_plan_slot(%Date{} = date, recipe_id, servings, ctx, meal \\ :dinner)
      when is_integer(recipe_id) and is_map(ctx) do
    servings = servings || @default_servings

    with {:ok, diff, run_ctx} <-
           Kinds.SetPlanSlot.proposal(ctx.scope, date, recipe_id, servings, meal),
         {:ok, %KitchenRun{} = run} <-
           Runs.submit(ctx.scope, Kinds.SetPlanSlot, diff, as_actor(run_ctx, ctx)) do
      slot_bubble(run, date, diff, meal)
    else
      {:error, reason} -> error_bubble(:plan, reason)
    end
  end

  defp slot_bubble(%KitchenRun{status: :applied, id: id}, date, diff, meal) do
    [%{payload: %{"label" => title}}] = diff.events

    %{
      role: :assistant,
      text:
        gettext("Added %{title} to %{day} %{date}.",
          title: title,
          day: day_for(date, meal),
          date: Date.to_iso8601(date)
        ),
      run_stream_id: id
    }
  end

  defp slot_bubble(%KitchenRun{status: :failed, failure_code: :slot_pinned}, date, _diff, _),
    do: pinned_bubble(date)

  defp slot_bubble(%KitchenRun{failure_code: code}, _date, _diff, _),
    do: error_bubble(:plan, code)

  @spec clear_plan_slot(Date.t(), ctx()) :: bubble()
  def clear_plan_slot(%Date{} = date, ctx, meal \\ :dinner) do
    edit_plan(ctx, {date, meal}, &%Planning.Commands.RemoveRecipe{slot_key: &1}, fn ->
      gettext("Cleared %{day} %{date}.", day: day_for(date, meal), date: Date.to_iso8601(date))
    end)
  end

  @doc "Marks `dates` as days off, or takes them off again: a day off offers a lunch."
  @spec set_days_off([Date.t()], boolean(), ctx()) :: bubble()
  def set_days_off([_ | _] = dates, off?, ctx) do
    result =
      if off?,
        do: Planning.mark_days_off(ctx.scope, dates),
        else: Planning.clear_days_off(ctx.scope, dates)

    days = dates |> Enum.sort(Date) |> Enum.map_join(", ", &Date.to_iso8601/1)

    case result do
      :ok when off? -> %{role: :assistant, text: gettext("Days off: %{days}.", days: days)}
      :ok -> %{role: :assistant, text: gettext("No longer days off: %{days}.", days: days)}
      {:error, reason} -> error_bubble(:plan, reason)
    end
  end

  # ── pantry-driven suggestions ──────────────────────────────────────────

  @doc """
  Whether `dish` can be made with what's at home. A recipe in the library (by `recipe_id`, or a
  title containing `dish`) is checked by its own ingredients; otherwise by `ingredients`, the
  model's idea of what the dish needs. The reply carries what's had and what's missing, and,
  for a library recipe, its id so it can be started.

  `lacking` is what they said they don't have, whatever the pantry says; `instead` what they said
  they'd use. Either one asks for swaps (`Tore.Recipes.Swaps`, one model call), the same check as
  the sheet before cooking. A plain "can I make it?" makes no call.
  """
  @spec can_i_make(String.t(), integer() | nil, [String.t()], ctx(), keyword()) :: bubble()
  def can_i_make(dish, recipe_id, ingredients, ctx, opts \\ []) when is_binary(dish) do
    recipe = library_recipe(ctx.scope, recipe_id, dish)
    lacking = Keyword.get(opts, :lacking, [])
    instead = Keyword.get(opts, :instead, "")

    names =
      if recipe,
        do: Enum.map(recipe.recipe_ingredients, & &1.ingredient.name),
        else: ingredients

    %{have: have, missing: missing} = Tore.Pantry.at_home(ctx.scope, names)
    {have, missing} = also_lacking(have, missing, lacking)
    title = if recipe, do: recipe.title, else: dish

    swaps =
      if missing != [] and (lacking != [] or String.trim(instead) != "") do
        recipe = recipe || %Tore.Recipes.Recipe{title: dish, recipe_ingredients: []}

        case Tore.Recipes.Swaps.check(ctx.scope, recipe, missing, instead) do
          {:ok, swaps} -> swaps
          {:error, _} -> nil
        end
      end

    %{
      role: :assistant,
      can_make: %{
        title: title,
        recipe_id: recipe && recipe.id,
        photo: recipe && recipe.image_path != nil,
        baking: recipe && recipe.recipe_type == :baking,
        have: have,
        missing: missing,
        swaps: swaps
      },
      text: can_make_text(title, missing)
    }
  end

  # What they said they lack is missing, even where the pantry thinks it's had.
  defp also_lacking(have, missing, lacking) do
    lacks? = fn name -> Enum.any?(lacking, &(String.downcase(&1) == String.downcase(name))) end
    {gone, have} = Enum.split_with(have, lacks?)
    known = Enum.map(have ++ gone ++ missing, &String.downcase/1)
    extra = Enum.reject(lacking, &(String.downcase(&1) in known))
    {have, missing ++ gone ++ extra}
  end

  defp library_recipe(scope, id, _dish) when is_integer(id) do
    case Recipes.get_many(scope, [id]) do
      [recipe] -> recipe
      [] -> nil
    end
  end

  defp library_recipe(scope, nil, dish) do
    wanted = String.downcase(dish)

    scope
    |> Recipes.search(dish)
    |> Enum.find(&String.contains?(String.downcase(&1.title), wanted))
    |> case do
      nil -> nil
      found -> library_recipe(scope, found.id, dish)
    end
  end

  defp can_make_text(dish, []), do: gettext("Everything for %{dish} is at home.", dish: dish)

  defp can_make_text(dish, missing) do
    ngettext(
      "%{dish}: one thing is missing, %{things}.",
      "%{dish}: %{count} things are missing, %{things}.",
      length(missing),
      dish: dish,
      things: Enum.join(missing, ", ")
    )
  end

  @spec suggest_meals_from_pantry(pos_integer(), ctx()) :: bubble()
  def suggest_meals_from_pantry(count, ctx) when is_integer(count) and count > 0 do
    today = Tore.Clock.today()
    plan_id = plan_stream_id_for(ctx, today)
    next_empty = next_empty_slot_key(ctx, today)

    case Planning.suggest_recipes_for_slot(ctx.scope, plan_id, next_empty, limit: count) do
      {:ok, []} ->
        %{
          role: :assistant,
          text:
            gettext(
              "Your recipe library is empty. Import a recipe and I'll suggest from your pantry next time."
            )
        }

      {:ok, ranked} ->
        suggestions =
          Enum.map(ranked, fn %{recipe: r, reasons: reasons} ->
            %{
              recipe_id: r.id,
              title: r.title,
              photo: r.image_path != nil,
              reasons: Enum.take(reasons, 2)
            }
          end)
          |> Enum.take(min(count, @suggestion_limit))

        %{
          role: :assistant,
          pantry_suggestions: true,
          suggestions: suggestions,
          text: gettext("Here's what works with what you have:")
        }

      {:error, reason} ->
        error_bubble(:suggest, reason)
    end
  end

  # ── shopping list ──────────────────────────────────────────────────────

  @spec add_to_shopping_list(String.t(), number() | nil, String.t() | nil, ctx()) :: bubble()
  def add_to_shopping_list(name, quantity, unit, ctx) when is_binary(name) do
    qty = Tore.Types.decimal(quantity)
    change = Kinds.ShopEdit.add(ctx.scope, current_shop_list_id(ctx), name, qty, unit)

    edit_shop(ctx, change, true, fn ->
      gettext("Added %{label} to the shopping list.", label: shopping_label(name, qty, unit))
    end)
  end

  # A shop change through a shop edit run. The reply offers Undo when the change has one.
  defp edit_shop(ctx, change, undoable?, applied_text) do
    case Runs.submit(ctx.scope, Kinds.ShopEdit, change, as_actor(%{change: change}, ctx)) do
      {:ok, %KitchenRun{status: :applied, id: id}} ->
        bubble = %{role: :assistant, shop_link: true, text: applied_text.()}
        if undoable?, do: Map.put(bubble, :run_stream_id, id), else: bubble

      {:ok, %KitchenRun{failure_code: code}} ->
        error_bubble(:shop, code)

      {:error, reason} ->
        error_bubble(:shop, reason)
    end
  end

  defp shopping_label(name, nil, _), do: name
  defp shopping_label(name, qty, nil), do: "#{format_qty(qty)} #{name}"
  defp shopping_label(name, qty, unit), do: "#{format_qty(qty)} #{unit} #{name}"

  defp format_qty(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_qty(other), do: to_string(other)

  @spec check_off_shopping_item(String.t(), ctx()) :: bubble()
  def check_off_shopping_item(name, ctx) when is_binary(name) do
    list_id = current_shop_list_id(ctx)

    case Shop.find_item_fuzzy(ctx.scope, list_id, name) do
      {:ok, {_id, item}} ->
        edit_shop(ctx, Kinds.ShopEdit.check(list_id, item), true, fn ->
          gettext("Checked off %{name}.", name: item.name)
        end)

      {:ambiguous, matches} ->
        names = matches |> Enum.map(fn {_id, it} -> it.name end) |> Enum.join(", ")

        %{
          role: :assistant,
          text:
            gettext("Multiple shopping items match \"%{q}\": %{names}. Which one?",
              q: name,
              names: names
            )
        }

      {:error, :not_found} ->
        %{
          role: :assistant,
          text:
            gettext("No shopping item matches \"%{q}\".",
              q: name
            )
        }
    end
  end

  @spec list_shopping_list(boolean(), ctx()) :: bubble()
  def list_shopping_list(unchecked_only?, ctx) when is_boolean(unchecked_only?) do
    list_id = current_shop_list_id(ctx)

    case Shop.load_list(ctx.scope, list_id) do
      {:ok, %{items: items}} when map_size(items) == 0 ->
        %{
          role: :assistant,
          shop_link: true,
          text: gettext("Your shopping list is empty.")
        }

      {:ok, %{items: items}} ->
        relevant =
          items
          |> Map.values()
          |> Enum.filter(fn it -> not unchecked_only? or not it.checked end)
          |> Enum.sort_by(& &1.name)

        rendered =
          Enum.map(relevant, fn it ->
            %{name: it.name, quantity: it.quantity, unit: it.unit, checked: it.checked}
          end)

        %{
          role: :assistant,
          shop_link: true,
          shopping_items: rendered,
          text:
            gettext("Shopping list (%{n} items):",
              n: length(rendered)
            )
        }

      {:error, reason} ->
        error_bubble(:shop, reason)
    end
  end

  @spec generate_shopping_list_from_plan(Date.t() | nil, ctx()) :: bubble()
  def generate_shopping_list_from_plan(date, ctx) do
    target_date = date || Tore.Clock.today()
    week_start = Streams.monday(target_date)
    list_id = Streams.shop_list(ctx.scope, week_start)
    plan_id = Streams.plan(ctx.scope, week_start)

    case Planning.load_plan(ctx.scope, plan_id) do
      {:ok, state} ->
        recipe_ids =
          state.slots
          |> Map.values()
          |> Enum.map(& &1[:recipe_id])
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        change = Kinds.ShopEdit.build(ctx.scope, list_id, week_start, recipe_ids)

        edit_shop(ctx, change, false, fn ->
          gettext(
            "Built a shopping list for the week of %{date} from %{n} planned recipes.",
            date: Date.to_iso8601(week_start),
            n: length(recipe_ids)
          )
        end)

      {:error, reason} ->
        error_bubble(:plan, reason)
    end
  end

  # ── budget and planning the week ───────────────────────────────────────

  @doc """
  Sets a budget the person stated: the week's own when `date` is given, otherwise the household's
  default. A setting, so it's written directly. `nil` removes it.
  """
  @spec set_budget(Decimal.t() | nil, Date.t() | nil, ctx()) :: bubble()
  def set_budget(amount, nil, ctx) do
    case Tore.Budget.set_default(ctx.scope, amount) do
      :ok when amount == nil ->
        %{role: :assistant, text: gettext("Removed the weekly budget.")}

      :ok ->
        %{
          role: :assistant,
          text: gettext("Weekly budget set to %{amount} kr.", amount: Tore.Money.format(amount))
        }

      {:error, reason} ->
        error_bubble(:budget, reason)
    end
  end

  def set_budget(amount, %Date{} = date, ctx) do
    week = date |> Streams.monday() |> Streams.week_number()

    case Tore.Budget.set_week(ctx.scope, Streams.monday(date), amount) do
      :ok when amount == nil ->
        %{
          role: :assistant,
          text: gettext("Week %{week} uses the usual budget again.", week: week)
        }

      :ok ->
        %{
          role: :assistant,
          text:
            gettext("Budget for week %{week} set to %{amount} kr.",
              week: week,
              amount: Tore.Money.format(amount)
            )
        }

      {:error, reason} ->
        error_bubble(:budget, reason)
    end
  end

  @doc """
  Adds the basics the person says they buy regularly, due every week, or with `stop: true` stops
  them. A standing preference, so it's written directly.
  """
  @spec set_basics([Tore.Basics.item()], boolean(), ctx()) :: bubble()
  def set_basics(items, stop?, ctx)

  def set_basics([], _stop?, _ctx),
    do: %{role: :assistant, error: true, text: gettext("Which things do you mean?")}

  def set_basics(items, false, ctx) do
    :ok = Tore.Basics.ask(ctx.scope, items)

    # Over MCP the server's model is never asked; the names are learned when the list is made.
    if ctx[:actor] != :mcp, do: Tore.Pantry.Learn.later(ctx.scope, Enum.map(items, & &1.name))

    %{
      role: :assistant,
      text:
        gettext("%{names} go on the list every week.",
          names: items |> Enum.map(& &1.name) |> Enum.join(", ")
        )
    }
  end

  def set_basics(items, true, ctx) do
    Enum.each(items, &Tore.Basics.stop(ctx.scope, &1.name))

    %{
      role: :assistant,
      text:
        gettext("%{names} won't be added to the list any more.",
          names: items |> Enum.map(& &1.name) |> Enum.join(", ")
        )
    }
  end

  @doc """
  Logs what the person says a week's shop cost, as a receipt with no lines, so the week gets a
  verdict without a photo. Undo deletes it.
  """
  @spec log_total(Decimal.t(), Date.t(), ctx()) :: bubble()
  def log_total(%Decimal{} = amount, %Date{} = date, ctx) do
    today = Tore.Clock.today()
    week_start = Streams.monday(date)

    if Date.compare(week_start, today) == :gt do
      %{role: :assistant, error: true, text: gettext("That week hasn't started yet.")}
    else
      cost = %CostEntry{
        store_name: gettext("Typed total"),
        date: Enum.min([today, Date.add(week_start, 6)], Date),
        total: amount,
        line_items: []
      }

      case Runs.submit(ctx.scope, Kinds.Receipt, cost, as_actor(%{week_start: week_start}, ctx)) do
        {:ok, %KitchenRun{status: :applied, id: id}} ->
          %{
            role: :assistant,
            text:
              gettext("Logged %{amount} kr for week %{week}.",
                amount: Tore.Money.format(amount),
                week: Streams.week_number(week_start)
              ),
            run_stream_id: id
          }

        {:ok, %KitchenRun{failure_code: code}} ->
          error_bubble(:receipt, code)

        {:error, reason} ->
          error_bubble(:receipt, reason)
      end
    end
  end

  @doc """
  Plans the week `date` falls in, as the plan screen's command does: `request` is what the person
  asked for, in their words. Answers with the week's estimate against its budget.
  """
  @spec plan_week(Date.t(), String.t(), ctx()) :: bubble()
  def plan_week(%Date{} = date, request, ctx) when is_binary(request) do
    week_start = Streams.monday(date)

    run_ctx = %{
      command: request,
      plan_stream_id: Streams.plan(ctx.scope, week_start),
      week_start: week_start
    }

    case Runs.start(ctx.scope, Kinds.PlannerCommand, as_actor(run_ctx, ctx)) do
      {:ok, %KitchenRun{status: :applied, id: id}} ->
        %{role: :assistant, text: week_planned_text(ctx.scope, week_start), run_stream_id: id}

      {:ok, %KitchenRun{status: :needs_user, question: question}} when is_binary(question) ->
        %{role: :assistant, text: question}

      {:ok, %KitchenRun{failure_code: code}} ->
        error_bubble(:plan, code)

      {:error, reason} ->
        error_bubble(:plan, reason)
    end
  end

  defp week_planned_text(scope, week_start) do
    %{budget: budget, estimate: estimate, expected: expected} =
      Tore.Budget.status(scope, week_start)

    week = Streams.week_number(week_start)

    cond do
      estimate.total == 0 ->
        gettext("Planned week %{week}.", week: week)

      budget == nil ->
        gettext(
          "Planned week %{week}: about %{amount} kr, %{priced} of %{total} ingredients priced.",
          week: week,
          amount: Tore.Money.format(expected),
          priced: estimate.priced,
          total: estimate.total
        )

      true ->
        gettext(
          "Planned week %{week}: about %{amount} of %{budget} kr, %{priced} of %{total} ingredients priced.",
          week: week,
          amount: Tore.Money.format(expected),
          budget: Tore.Money.format(budget),
          priced: estimate.priced,
          total: estimate.total
        )
    end
  end

  # ── pantry mutations ───────────────────────────────────────────────────

  @spec add_to_pantry(String.t(), number() | nil, String.t() | nil, ctx()) :: bubble()
  def add_to_pantry(name, quantity, unit, ctx) when is_binary(name) do
    item = %{name: name, quantity: Tore.Types.decimal(quantity), unit: unit}

    case Runs.start(
           ctx.scope,
           Kinds.PantryUpdate,
           as_actor(%{channel: :manual, items: [item]}, ctx)
         ) do
      {:ok, %KitchenRun{status: :applied, id: id, undo: {:steps, [step]}}} ->
        text =
          case step do
            {:restore_pantry_item, _id, :absent} ->
              gettext("Added %{name} to the pantry.", name: name)

            {:restore_pantry_item, _id, _before} ->
              gettext("Bumped %{name} in the pantry.", name: name)
          end

        %{role: :assistant, text: text, run_stream_id: id}

      {:ok, %KitchenRun{failure_code: code}} ->
        error_bubble(:pantry, code)

      {:error, reason} ->
        error_bubble(:pantry, reason)
    end
  end

  @spec remove_from_pantry(String.t(), ctx()) :: bubble()
  def remove_from_pantry(name, ctx) when is_binary(name) do
    case Pantry.find_by_name_fuzzy(ctx.scope, name) do
      {:ok, item} ->
        removal = %{name: item.name, item_id: item.id}

        case Runs.start(
               ctx.scope,
               Kinds.PantryUpdate,
               as_actor(%{channel: :manual, items: [removal]}, ctx)
             ) do
          {:ok, %KitchenRun{status: :applied, id: id}} ->
            %{
              role: :assistant,
              text: gettext("Removed %{name} from the pantry.", name: item.name),
              run_stream_id: id
            }

          {:ok, %KitchenRun{failure_code: code}} ->
            error_bubble(:pantry, code)

          {:error, reason} ->
            error_bubble(:pantry, reason)
        end

      {:ambiguous, matches} ->
        names = matches |> Enum.map(& &1.name) |> Enum.join(", ")

        %{
          role: :assistant,
          text:
            gettext("Multiple pantry items match \"%{q}\": %{names}. Which one?",
              q: name,
              names: names
            )
        }

      {:error, :not_found} ->
        %{
          role: :assistant,
          text:
            gettext("Nothing in the pantry matches \"%{q}\".",
              q: name
            )
        }
    end
  end

  @spec check_pantry(String.t(), ctx()) :: bubble()
  def check_pantry(name, ctx) when is_binary(name) do
    case Pantry.find_by_name_fuzzy(ctx.scope, name) do
      {:ok, item} ->
        qty_str =
          case {item.quantity, item.unit} do
            {nil, _} -> ""
            {q, nil} -> " (#{q})"
            {q, u} -> " (#{q} #{u})"
          end

        %{
          role: :assistant,
          text:
            gettext("Yes — %{name}%{qty} is in the pantry.",
              name: item.name,
              qty: qty_str
            )
        }

      {:ambiguous, matches} ->
        names = matches |> Enum.map(& &1.name) |> Enum.join(", ")

        %{
          role: :assistant,
          text:
            gettext("Several pantry items match: %{names}.",
              names: names
            )
        }

      {:error, :not_found} ->
        %{
          role: :assistant,
          text:
            gettext("No, %{name} isn't in the pantry.",
              name: name
            )
        }
    end
  end

  # ── plan-slot adjustments ──────────────────────────────────────────────

  @spec mark_recipe_cooked(integer(), ctx()) :: bubble()
  def mark_recipe_cooked(recipe_id, ctx) when is_integer(recipe_id) do
    :ok = Recipes.record_used(ctx.scope, recipe_id)

    %{
      role: :assistant,
      text: gettext("Marked the recipe as cooked tonight.")
    }
  end

  @spec set_plan_servings(Date.t(), pos_integer(), ctx(), Streams.meal()) :: bubble()
  def set_plan_servings(%Date{} = date, servings, ctx, meal \\ :dinner)
      when is_integer(servings) and servings > 0 do
    command = &%Planning.Commands.SetServings{slot_key: &1, servings: servings}

    edit_plan(ctx, {date, meal}, command, fn ->
      gettext("Set servings on %{day} %{date} to %{n}.",
        day: day_for(date, meal),
        date: Date.to_iso8601(date),
        n: servings
      )
    end)
  end

  @spec pin_plan_slot(Date.t(), boolean(), ctx(), Streams.meal()) :: bubble()
  def pin_plan_slot(date, pinned?, ctx, meal \\ :dinner)

  def pin_plan_slot(%Date{} = date, true, ctx, meal) do
    edit_plan(ctx, {date, meal}, &%Planning.Commands.PinSlot{slot_key: &1, pin: true}, fn ->
      gettext("Pinned %{day} %{date}.", day: day_for(date, meal), date: Date.to_iso8601(date))
    end)
  end

  def pin_plan_slot(%Date{} = date, false, ctx, meal) do
    edit_plan(ctx, {date, meal}, &%Planning.Commands.UnpinSlot{slot_key: &1}, fn ->
      gettext("Unpinned %{day} %{date}.", day: day_for(date, meal), date: Date.to_iso8601(date))
    end)
  end

  @spec skip_plan_meal(Date.t(), ctx()) :: bubble()
  def skip_plan_meal(%Date{} = date, ctx) do
    edit_plan(ctx, date, &%Planning.Commands.SkipMeal{slot_key: &1}, fn ->
      gettext("Marked %{day} %{date} as skipped.",
        day: long_day_for(date),
        date: Date.to_iso8601(date)
      )
    end)
  end

  @doc "`attrs` holds the optional `:place` and `:amount`; what isn't given stays as it was."
  @spec mark_eating_out(Date.t(), map(), ctx()) :: bubble()
  def mark_eating_out(%Date{} = date, attrs, ctx) do
    command =
      &%Planning.Commands.EatOut{slot_key: &1, place: attrs[:place], amount: attrs[:amount]}

    edit_plan(ctx, date, command, fn ->
      gettext("Marked %{date} as eating out.", date: Date.to_iso8601(date))
    end)
  end

  # One day's change through a plan edit run, so a pinned day holds and the reply can undo it.
  defp edit_plan(ctx, %Date{} = date, command, applied_text),
    do: edit_plan(ctx, {date, :dinner}, command, applied_text)

  defp edit_plan(ctx, {date, meal}, command, applied_text) do
    plan_id = plan_stream_id_for(ctx, date)
    command = command.(Streams.slot_key(date, meal))

    with {:ok, diff, run_ctx} <- Kinds.PlanEdit.proposal(ctx.scope, plan_id, command),
         {:ok, %KitchenRun{} = run} <-
           Runs.submit(ctx.scope, Kinds.PlanEdit, diff, as_actor(run_ctx, ctx)) do
      case run do
        %KitchenRun{status: :applied, id: id} ->
          %{role: :assistant, text: applied_text.(), run_stream_id: id}

        %KitchenRun{failure_code: :slot_pinned} ->
          pinned_bubble(date)

        %KitchenRun{failure_code: code} ->
          error_bubble(:plan, code)
      end
    else
      {:error, reason} -> error_bubble(:plan, reason)
    end
  end

  defp pinned_bubble(date) do
    %{
      role: :assistant,
      text: gettext("%{day} is pinned, so I left it as it was.", day: long_day_for(date))
    }
  end

  # ── deleting ───────────────────────────────────────────────────────────
  # Plain deletes, with no review and no undo: the person asked for them.

  @spec remove_shopping_item(String.t(), ctx()) :: bubble()
  def remove_shopping_item(name, ctx) when is_binary(name) do
    list_id = current_shop_list_id(ctx)

    case Shop.find_item_fuzzy(ctx.scope, list_id, name) do
      {:ok, {id, item}} ->
        case Shop.remove_item(ctx.scope, list_id, id, ctx.scope.user_id) do
          {:ok, _events} ->
            %{
              role: :assistant,
              shop_link: true,
              text: gettext("Removed %{name} from the shopping list.", name: item.name)
            }

          {:error, reason} ->
            error_bubble(:shop, reason)
        end

      {:ambiguous, matches} ->
        names = Enum.map_join(matches, ", ", fn {_id, it} -> it.name end)

        %{
          role: :assistant,
          text:
            gettext("Multiple shopping items match \"%{q}\": %{names}. Which one?",
              q: name,
              names: names
            )
        }

      {:error, :not_found} ->
        %{role: :assistant, text: gettext("No shopping item matches \"%{q}\".", q: name)}
    end
  end

  @spec delete_recipe(integer(), ctx()) :: bubble()
  def delete_recipe(recipe_id, ctx) when is_integer(recipe_id) do
    case Recipes.get(ctx.scope, recipe_id) do
      nil ->
        %{role: :assistant, text: gettext("I couldn't find that recipe.")}

      recipe ->
        case Recipes.delete(ctx.scope, recipe) do
          {:ok, _} -> %{role: :assistant, text: gettext("Deleted %{title}.", title: recipe.title)}
          {:error, reason} -> error_bubble(:recipe, reason)
        end
    end
  end

  @spec list_receipts(ctx()) :: bubble()
  def list_receipts(ctx) do
    receipts =
      for r <- Costs.recent_receipts(ctx.scope, 10) do
        %{id: r.id, store: r.store_name, date: r.date, total: r.total_amount}
      end

    text =
      case receipts do
        [] -> gettext("No receipts yet.")
        _ -> Enum.map_join(receipts, "\n", &"#{&1.date} · #{&1.store} · #{&1.total} kr")
      end

    %{role: :assistant, quiet: true, receipts: receipts, text: text}
  end

  @spec delete_receipt(integer(), ctx()) :: bubble()
  def delete_receipt(receipt_id, ctx) when is_integer(receipt_id) do
    case Costs.delete_receipt(ctx.scope, receipt_id) do
      :ok -> %{role: :assistant, text: gettext("Deleted the receipt.")}
      {:error, :not_found} -> %{role: :assistant, text: gettext("I couldn't find that receipt.")}
    end
  end

  # ── quick swaps ────────────────────────────────────────────────────────

  @doc """
  Shows the swaps a turn suggests above this person's chat box (`Tore.Home.suggested_swaps/1`).
  Nothing is stored. Invalid ones come back with the rejection, for the model to correct.
  """
  @spec quick_swaps(term(), ctx()) :: bubble()
  def quick_swaps(raw, ctx) do
    case Tore.Home.suggested_swaps(raw) do
      {:ok, swaps} ->
        if ctx.scope.user_id do
          Phoenix.PubSub.broadcast(
            Tore.PubSub,
            Tore.Home.swaps_topic(ctx.scope.user_id),
            {:quick_swaps, swaps}
          )
        end

        %{role: :assistant, text: ""}

      {:error, reason} ->
        %{role: :assistant, text: "", rejection: reason}
    end
  end

  # ── memory ─────────────────────────────────────────────────────────────

  @doc """
  One batch of memory operations on `target` ("profile" or "notes"), saved through a memory
  update run. The reply is a quiet "Noted:", "Updated:" or "Forgot:" line with Undo. A batch that
  doesn't fit opens no run: the model gets the rejection to try again, and the person sees
  nothing, unless it was an allergy, which belongs on the kitchen page instead.
  """
  @spec memory(term(), term(), ctx()) :: bubble()
  def memory(target, operations, ctx) do
    batch = %MemoryBatch{target: target, operations: operations}

    case Kinds.MemoryReview.check(ctx.scope, [batch]) do
      :ok ->
        case Runs.submit(ctx.scope, Kinds.MemoryUpdate, [batch], as_actor(%{batch: batch}, ctx)) do
          {:ok, %KitchenRun{status: :applied} = run} ->
            run |> memory_bubble() |> Map.put(:memory, Memory.snapshot(ctx.scope))

          {:ok, %KitchenRun{failure_code: code}} ->
            error_bubble(:memory, code)

          {:error, reason} ->
            error_bubble(:memory, reason)
        end

      {:error, %{"refused" => "allergy"} = rejection} ->
        %{
          role: :assistant,
          kitchen_link: true,
          rejection: rejection,
          text:
            gettext(
              "I don't keep allergies as notes. Add it on the kitchen page, where every plan is checked against it."
            )
        }

      {:error, rejection} ->
        %{role: :assistant, text: "", rejection: rejection}
    end
  end

  defp memory_bubble(%KitchenRun{artifacts: [%MemoryBatch{changes: []}]}),
    do: %{role: :assistant, quiet: true, text: gettext("Already noted.")}

  defp memory_bubble(%KitchenRun{id: id, artifacts: [%MemoryBatch{changes: changes}]}) do
    %{
      role: :assistant,
      quiet: true,
      run_stream_id: id,
      text: Enum.map_join(changes, "\n", &memory_line/1)
    }
  end

  defp memory_line(%{"kind" => "noted", "text" => text}),
    do: gettext("Noted: %{text}", text: text)

  defp memory_line(%{"kind" => "updated", "text" => text}),
    do: gettext("Updated: %{text}", text: text)

  defp memory_line(%{"kind" => "forgot", "text" => text}),
    do: gettext("Forgot: %{text}", text: text)

  # ── unrecognised image ─────────────────────────────────────────────────

  @spec report_unrecognised_image(String.t() | nil) :: bubble()
  def report_unrecognised_image(suggestion) do
    text =
      case suggestion do
        s when is_binary(s) and s != "" ->
          s

        _ ->
          gettext(
            "I wasn't sure what that photo showed. Could you tell me — is it a receipt, a recipe, or your fridge?"
          )
      end

    %{role: :assistant, text: text}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # The hash is recorded before the photo is read, so two uploads of the same bytes at once
  # can't both start a run. A photo whose reading failed is forgotten again, so it can be
  # retried.
  defp with_dedup(image, scope, kind, run_fn) do
    hash = Uploads.content_hash(image)
    upload_id = KitchenRun.new_id()

    case Uploads.record(scope, hash, upload_id, kind) do
      {:ok, ^upload_id} ->
        case run_fn.() do
          {:ok, result} ->
            result

          {:failed, result} ->
            Uploads.forget(scope, hash)
            result
        end

      {:duplicate, _upload_id} ->
        :duplicate
    end
  end

  defp duplicate_text, do: gettext("You've already uploaded this photo.")

  defp current_shop_list_id(ctx), do: Streams.shop_list(ctx.scope, Tore.Clock.today())

  defp plan_stream_id_for(ctx, %Date{} = date), do: Streams.plan(ctx.scope, date)

  defp day_for(date, :dinner), do: long_day_for(date)
  defp day_for(date, :lunch), do: gettext("%{day} lunch", day: long_day_for(date))

  defp long_day_for(%Date{} = date) do
    case Date.day_of_week(date) do
      1 -> pgettext("in a sentence", "Monday")
      2 -> pgettext("in a sentence", "Tuesday")
      3 -> pgettext("in a sentence", "Wednesday")
      4 -> pgettext("in a sentence", "Thursday")
      5 -> pgettext("in a sentence", "Friday")
      6 -> pgettext("in a sentence", "Saturday")
      7 -> pgettext("in a sentence", "Sunday")
    end
  end

  defp next_empty_slot_key(ctx, %Date{} = today) do
    case Planning.load_plan(ctx.scope, plan_stream_id_for(ctx, today)) do
      {:ok, state} ->
        today_idx = Date.day_of_week(today) - 1

        Enum.drop(@days, today_idx)
        |> Enum.find_value(fn day ->
          slot_key = "#{day}_dinner"

          case Map.get(state.slots, slot_key) do
            nil -> slot_key
            %{reason: "eating_out"} -> nil
            %{recipe_id: nil} -> slot_key
            _ -> nil
          end
        end) || Streams.slot_key(today)

      _ ->
        Streams.slot_key(today)
    end
  end

  # The reason rides along for a caller that can act on it (MCP); Capture shows only the text.
  defp error_bubble(kind, reason),
    do: %{role: :assistant, error: true, text: error_text(kind, reason), reason: reason}

  # A run opened for MCP is recorded as MCP's, not the person's in the app.
  defp as_actor(run_ctx, ctx), do: Map.merge(run_ctx, Map.take(ctx, [:actor]))

  defp error_text(kind, reason) do
    require Logger
    Logger.warning("Capture.Dispatch #{kind} failed: #{inspect(reason)}")

    gettext("Something went wrong. Please try again.")
  end
end
