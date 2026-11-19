defmodule Tore.Capture.Dispatch do
  @moduledoc """
  The writes behind Tore's MCP tools, each through a run where it can be undone, answering
  with a bubble: the words to say and, when it can be undone, the run's id
  (`Tore.Mcp.Tool` turns it into the tool's result). The shopping list's receipt photo and the
  Recipes screen's link import call `read_receipt/2` and `import_recipe_from_url/2` directly.
  """

  use Gettext, backend: ToreWeb.Gettext

  alias Tore.Capture.Uploads
  alias Tore.Costs
  alias Tore.Harness.Artifact.{CostEntry, MemoryBatch}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Kinds
  alias Tore.Household.Memory
  alias Tore.Pantry
  alias Tore.Planning
  alias Tore.Recipes
  alias Tore.Shop
  alias Tore.Streams

  @default_servings 4

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

  defp receipt_text(%KitchenRun{artifacts: [%CostEntry{} = cost]}) do
    gettext("Saved the receipt from %{store}: %{total} kr.",
      store: cost.store_name,
      total: Decimal.to_string(Decimal.round(cost.total, 2), :normal)
    )
  end

  # ── recipe ─────────────────────────────────────────────────────────────

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

  defp slot_bubble(%KitchenRun{status: :failed, failure_code: :slot_eating_out}, date, _diff, _) do
    %{
      role: :assistant,
      text:
        gettext("You're eating out on %{day}, so I left it. Clear the day first to cook there.",
          day: long_day_for(date)
        )
    }
  end

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

  # ── budget and basics ──────────────────────────────────────────────────

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

  # ── pantry mutations ───────────────────────────────────────────────────

  @doc """
  Puts something in the pantry. `seen` says it was seen at home, as on a photo of a shelf: then
  `quantity` is what's there now rather than what came in, and `seen` may give the date printed
  on it (`:expires_on`) and how many days this food keeps (`:shelf_life_days`).
  """
  @spec add_to_pantry(String.t(), number() | nil, String.t() | nil, ctx(), map() | nil) ::
          bubble()
  def add_to_pantry(name, quantity, unit, ctx, seen \\ nil) when is_binary(name) do
    item =
      Map.merge(
        %{name: name, quantity: Tore.Types.decimal(quantity), unit: unit},
        Map.take(seen || %{}, [:expires_on, :shelf_life_days])
      )

    channel = if seen, do: :seen, else: :manual

    case Runs.start(
           ctx.scope,
           Kinds.PantryUpdate,
           as_actor(%{channel: channel, items: [item]}, ctx)
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

  @spec delete_receipt(integer(), ctx()) :: bubble()
  def delete_receipt(receipt_id, ctx) when is_integer(receipt_id) do
    case Costs.delete_receipt(ctx.scope, receipt_id) do
      :ok -> %{role: :assistant, text: gettext("Deleted the receipt.")}
      {:error, :not_found} -> %{role: :assistant, text: gettext("I couldn't find that receipt.")}
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

    case Kinds.MemoryUpdate.check(ctx.scope, [batch]) do
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
