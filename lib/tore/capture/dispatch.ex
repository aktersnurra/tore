defmodule Tore.Capture.Dispatch do
  @moduledoc """
  Handlers invoked by `Tore.Capture.Router` when the model emits a tool call.

  Each function corresponds 1:1 to a tool in the catalogue and produces a
  rendered assistant bubble (a plain map the LiveView already renders).

  These are the bodies that used to live inside `Tore.PhotoPipeline.route_group/3`,
  one per channel, lifted out so the router can call them directly.
  """

  use Gettext, backend: ToreWeb.Gettext

  alias Tore.Capture.Uploads
  alias Tore.Costs
  alias Tore.Harness.Artifact.{CostEntry, MemoryBatch, PantryBeliefUpdate}
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Kinds
  alias Tore.Pantry
  alias Tore.Planning
  alias Tore.Recipes
  alias Tore.Shop
  alias Tore.Streams
  alias Tore.Storage.RunPhotos

  @days ~w(mon tue wed thu fri sat sun)
  @default_servings 4
  @suggestion_limit 4

  @type ctx :: %{
          required(:household_id) => integer(),
          optional(:user_id) => integer() | nil
        }
  @type bubble :: map()

  # ── receipt ────────────────────────────────────────────────────────────

  @spec ingest_receipt(binary(), ctx()) :: bubble()
  def ingest_receipt(image, ctx) when is_binary(image) do
    with_dedup(image, ctx, "receipt", fn upload_id ->
      image_path = stash_photo(scope(ctx), upload_id, image)

      case Runs.start(scope(ctx), Kinds.Receipt, %{image_binary: image, image_path: image_path}) do
        {:ok, %KitchenRun{status: :needs_user, id: id}} ->
          review_bubble(:receipt, id)

        {:ok, %KitchenRun{status: :applied} = run} ->
          receipt_bubble(run)

        {:ok, %KitchenRun{status: :failed, failure_code: code}} ->
          if image_path, do: RunPhotos.delete_async(image_path)
          error_bubble(:receipt, code)

        {:error, reason} ->
          if image_path, do: RunPhotos.delete_async(image_path)
          error_bubble(:receipt, reason)
      end
    end)
  end

  defp receipt_bubble(%KitchenRun{id: id, artifacts: [%CostEntry{} = cost]}) do
    %{
      role: :assistant,
      text:
        gettext("Saved the receipt from %{store}: %{total} kr.",
          store: cost.store_name,
          total: Decimal.to_string(Decimal.round(cost.total, 2), :normal)
        ),
      run_stream_id: id
    }
  end

  # ── shelf → pantry update ──────────────────────────────────────────────

  @spec update_pantry_from_shelf(binary(), ctx()) :: bubble()
  def update_pantry_from_shelf(image, ctx) when is_binary(image) do
    with_dedup(image, ctx, "shelf", fn _upload_id ->
      case Runs.start(scope(ctx), Kinds.PantryUpdate, %{
             channel: :shelf_photo,
             image_binary: image
           }) do
        {:ok, %KitchenRun{status: :applied} = run} ->
          shelf_bubble(run)

        {:ok, %KitchenRun{status: :failed, failure_code: code}} ->
          error_bubble(:pantry, code)

        {:error, reason} ->
          error_bubble(:pantry, reason)
      end
    end)
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
    case Runs.start(scope(ctx), Kinds.RecipeIngestion, %{images: images}) do
      {:error, {:step_failed, reason}} ->
        refusal_bubble(reason) || error_bubble(:recipe, reason)

      result ->
        recipe_bubble(result)
    end
  end

  # A recipe read from photos or a page waits for review before it is saved.
  defp recipe_bubble({:ok, %KitchenRun{status: :needs_user, id: id, artifacts: [proposal]}}) do
    %{
      role: :assistant,
      review_link: true,
      stream_id: id,
      text: gettext("I read %{title}. Review it before it's saved.", title: proposal.title)
    }
  end

  defp recipe_bubble({:ok, %KitchenRun{failure_code: :near_duplicate}}),
    do: %{role: :assistant, text: gettext("That looks like a recipe you already have.")}

  defp recipe_bubble({:ok, %KitchenRun{failure_code: code}}) do
    require Logger
    Logger.info("Capture recipe ingestion failed its check: #{inspect(code)}")
    %{role: :assistant, text: gettext("I couldn't read a whole recipe from that.")}
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
    case Tore.Pantry.parse_image(scope(ctx), image) do
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
    case Runs.start(scope(ctx), Kinds.RecipeIngestion, %{url: url}) do
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
    case Recipes.search(scope(ctx), query) do
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

  @doc "Puts a recipe on a day through a run, so a pinned day stays as it is."
  @spec set_plan_slot(Date.t(), integer(), integer() | nil, ctx()) :: bubble()
  def set_plan_slot(%Date{} = date, recipe_id, servings, ctx)
      when is_integer(recipe_id) and is_map(ctx) do
    with {:ok, diff, run_ctx} <-
           Kinds.SetPlanSlot.proposal(scope(ctx), date, recipe_id, servings || @default_servings),
         {:ok, %KitchenRun{} = run} <- Runs.submit(scope(ctx), Kinds.SetPlanSlot, diff, run_ctx) do
      slot_bubble(run, date, diff)
    else
      {:error, reason} -> error_bubble(:plan, reason)
    end
  end

  defp slot_bubble(%KitchenRun{status: :applied, id: id}, date, diff) do
    [%{payload: %{"label" => title}}] = diff.events

    %{
      role: :assistant,
      text:
        gettext("Added %{title} to %{day} %{date}.",
          title: title,
          day: long_day_for(date),
          date: Date.to_iso8601(date)
        ),
      run_stream_id: id
    }
  end

  defp slot_bubble(%KitchenRun{status: :failed, failure_code: :slot_pinned}, date, _diff),
    do: pinned_bubble(date)

  defp slot_bubble(%KitchenRun{failure_code: code}, _date, _diff), do: error_bubble(:plan, code)

  @spec clear_plan_slot(Date.t(), ctx()) :: bubble()
  def clear_plan_slot(%Date{} = date, ctx) do
    edit_plan(ctx, date, &%Planning.Commands.RemoveRecipe{slot_key: &1}, fn ->
      gettext("Cleared %{day} %{date}.", day: long_day_for(date), date: Date.to_iso8601(date))
    end)
  end

  # ── pantry-driven suggestions ──────────────────────────────────────────

  @spec suggest_meals_from_pantry(pos_integer(), ctx()) :: bubble()
  def suggest_meals_from_pantry(count, ctx) when is_integer(count) and count > 0 do
    today = Date.utc_today()
    plan_id = plan_stream_id_for(ctx, today)
    next_empty = next_empty_slot_key(ctx, today)

    case Planning.suggest_recipes_for_slot(scope(ctx), plan_id, next_empty, limit: count) do
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
            %{recipe_id: r.id, title: r.title, reasons: Enum.take(reasons, 2)}
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
    qty = to_decimal(quantity)
    change = Kinds.ShopEdit.add(scope(ctx), current_shop_list_id(ctx), name, qty, unit)

    edit_shop(ctx, change, true, fn ->
      gettext("Added %{label} to the shopping list.", label: shopping_label(name, qty, unit))
    end)
  end

  # A shop change through a shop edit run. The reply offers Undo when the change has one.
  defp edit_shop(ctx, change, undoable?, applied_text) do
    case Runs.submit(scope(ctx), Kinds.ShopEdit, change, %{change: change}) do
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

    case Shop.find_item_fuzzy(scope(ctx), list_id, name) do
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

    case Shop.load_list(scope(ctx), list_id) do
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
    target_date = date || Date.utc_today()
    week_start = Streams.monday(target_date)
    list_id = Streams.shop_list(scope(ctx), week_start)
    plan_id = Streams.plan(scope(ctx), week_start)

    case Planning.load_plan(scope(ctx), plan_id) do
      {:ok, state} ->
        recipe_ids =
          state.slots
          |> Map.values()
          |> Enum.map(& &1[:recipe_id])
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        change = Kinds.ShopEdit.build(scope(ctx), list_id, week_start, recipe_ids)

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

  # ── pantry mutations ───────────────────────────────────────────────────

  @spec add_to_pantry(String.t(), number() | nil, String.t() | nil, ctx()) :: bubble()
  def add_to_pantry(name, quantity, unit, ctx) when is_binary(name) do
    item = %{name: name, quantity: to_decimal(quantity), unit: unit}

    case Runs.start(scope(ctx), Kinds.PantryUpdate, %{channel: :manual, items: [item]}) do
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
    case Pantry.find_by_name_fuzzy(scope(ctx), name) do
      {:ok, item} ->
        removal = %{name: item.name, item_id: item.id}

        case Runs.start(scope(ctx), Kinds.PantryUpdate, %{channel: :manual, items: [removal]}) do
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
    case Pantry.find_by_name_fuzzy(scope(ctx), name) do
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
    :ok = Recipes.record_used(scope(ctx), recipe_id)

    %{
      role: :assistant,
      text: gettext("Marked the recipe as cooked tonight.")
    }
  end

  @spec set_plan_servings(Date.t(), pos_integer(), ctx()) :: bubble()
  def set_plan_servings(%Date{} = date, servings, ctx)
      when is_integer(servings) and servings > 0 do
    command = &%Planning.Commands.SetServings{slot_key: &1, servings: servings}

    edit_plan(ctx, date, command, fn ->
      gettext("Set servings on %{day} %{date} to %{n}.",
        day: long_day_for(date),
        date: Date.to_iso8601(date),
        n: servings
      )
    end)
  end

  @spec pin_plan_slot(Date.t(), boolean(), ctx()) :: bubble()
  def pin_plan_slot(%Date{} = date, true, ctx) do
    edit_plan(ctx, date, &%Planning.Commands.PinSlot{slot_key: &1, pin: true}, fn ->
      gettext("Pinned %{day} %{date}.", day: long_day_for(date), date: Date.to_iso8601(date))
    end)
  end

  def pin_plan_slot(%Date{} = date, false, ctx) do
    edit_plan(ctx, date, &%Planning.Commands.UnpinSlot{slot_key: &1}, fn ->
      gettext("Unpinned %{day} %{date}.", day: long_day_for(date), date: Date.to_iso8601(date))
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
  defp edit_plan(ctx, date, command, applied_text) do
    plan_id = plan_stream_id_for(ctx, date)
    command = command.(slot_key_for(date))

    with {:ok, diff, run_ctx} <- Kinds.PlanEdit.proposal(scope(ctx), plan_id, command),
         {:ok, %KitchenRun{} = run} <- Runs.submit(scope(ctx), Kinds.PlanEdit, diff, run_ctx) do
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

    case Shop.find_item_fuzzy(scope(ctx), list_id, name) do
      {:ok, {id, item}} ->
        case Shop.remove_item(scope(ctx), list_id, id, ctx[:user_id]) do
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
    case Recipes.get(scope(ctx), recipe_id) do
      nil ->
        %{role: :assistant, text: gettext("I couldn't find that recipe.")}

      recipe ->
        case Recipes.delete(scope(ctx), recipe) do
          {:ok, _} -> %{role: :assistant, text: gettext("Deleted %{title}.", title: recipe.title)}
          {:error, reason} -> error_bubble(:recipe, reason)
        end
    end
  end

  @spec list_receipts(ctx()) :: bubble()
  def list_receipts(ctx) do
    receipts =
      for r <- Costs.recent_receipts(scope(ctx), 10) do
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
    case Costs.delete_receipt(scope(ctx), receipt_id) do
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
  @spec memory(String.t(), list(), ctx()) :: bubble()
  def memory(target, operations, ctx) do
    batch = %MemoryBatch{target: target, operations: operations}

    case Kinds.MemoryReview.check(scope(ctx), [batch]) do
      :ok ->
        case Runs.submit(scope(ctx), Kinds.MemoryUpdate, [batch], %{batch: batch}) do
          {:ok, %KitchenRun{status: :applied} = run} -> memory_bubble(run)
          {:ok, %KitchenRun{failure_code: code}} -> error_bubble(:memory, code)
          {:error, reason} -> error_bubble(:memory, reason)
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

  defp scope(ctx), do: %Tore.Scope{household_id: ctx.household_id, user_id: ctx[:user_id]}

  # Race-safe: reserve an upload id, then try to record the hash. If the
  # unique index trips, another upload already claimed these bytes, so no
  # duplicate run starts. The id also names the stashed photo.
  defp with_dedup(image, ctx, kind, run_fn) do
    hash = Uploads.content_hash(image)
    upload_id = KitchenRun.new_id()

    case Uploads.record(scope(ctx), hash, upload_id, kind) do
      {:ok, ^upload_id} -> run_fn.(upload_id)
      {:duplicate, existing_stream_id} -> duplicate_bubble(kind, existing_stream_id)
    end
  end

  defp duplicate_bubble(_kind, _stream_id) do
    %{
      role: :assistant,
      review_link: true,
      text: gettext("You've already uploaded this photo.")
    }
  end

  defp stash_photo(scope, stream_id, image) do
    case RunPhotos.store(scope, stream_id, image) do
      {:ok, key} ->
        key

      {:error, reason} ->
        require Logger
        Logger.warning("RunPhotos.store failed: #{inspect(reason)} (run continues)")
        nil
    end
  end

  defp review_bubble(:receipt, sid) do
    %{role: :assistant, review_link: true, stream_id: sid, text: gettext("I parsed a receipt.")}
  end

  defp current_shop_list_id(ctx), do: Streams.shop_list(scope(ctx), Date.utc_today())

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp to_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _} -> d
      :error -> nil
    end
  end

  defp plan_stream_id_for(ctx, %Date{} = date), do: Streams.plan(scope(ctx), date)

  defp slot_key_for(%Date{} = date) do
    day_abbrev = Enum.at(@days, Date.day_of_week(date) - 1)
    "#{day_abbrev}_dinner"
  end

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
    case Planning.load_plan(scope(ctx), plan_stream_id_for(ctx, today)) do
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
        end) || "#{Enum.at(@days, today_idx)}_dinner"

      _ ->
        "#{Enum.at(@days, Date.day_of_week(today) - 1)}_dinner"
    end
  end

  defp error_bubble(kind, reason) do
    require Logger
    Logger.warning("Capture.Dispatch #{kind} failed: #{inspect(reason)}")

    %{role: :assistant, text: gettext("Something went wrong. Please try again.")}
  end
end
