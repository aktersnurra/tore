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
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run
  alias Tore.Harness.Run.State
  alias Tore.Pantry
  alias Tore.Planning
  alias Tore.Recipes
  alias Tore.Shop
  alias Tore.Storage.RunPhotos

  @days ~w(mon tue wed thu fri sat sun)
  @day_long ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
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
    with_dedup(image, ctx, "receipt", fn stream_id ->
      image_path = stash_photo(stream_id, image)

      dispatch_ctx = %{
        household_id: ctx.household_id,
        user_id: ctx[:user_id],
        stream_id: stream_id,
        image_binary: image,
        image_path: image_path
      }

      case Orchestrator.dispatch(:receipt_ingestion_run, dispatch_ctx) do
        {:ok, %State.NeedsUser{stream_id: sid}} ->
          review_bubble(:receipt, sid)

        {:ok, %State.Failed{failure_code: code}} ->
          if image_path, do: RunPhotos.delete_async(image_path)
          error_bubble(:receipt, code)

        {:error, reason} ->
          if image_path, do: RunPhotos.delete_async(image_path)
          error_bubble(:receipt, reason)
      end
    end)
  end

  # ── shelf → pantry update ──────────────────────────────────────────────

  @spec update_pantry_from_shelf(binary(), ctx()) :: bubble()
  def update_pantry_from_shelf(image, ctx) when is_binary(image) do
    with_dedup(image, ctx, "shelf", fn stream_id ->
      image_path = stash_photo(stream_id, image)

      dispatch_ctx = %{
        household_id: ctx.household_id,
        user_id: ctx[:user_id],
        stream_id: stream_id,
        channel: :shelf_photo,
        image_binary: image,
        image_path: image_path
      }

      case Orchestrator.dispatch(:pantry_belief_update_run, dispatch_ctx) do
        {:ok, %State.NeedsUser{stream_id: sid}} ->
          review_bubble(:pantry, sid)

        {:ok, %State.Applied{}} ->
          %{role: :assistant, text: Gettext.dgettext(ToreWeb.Gettext, "default", "Added the pantry items from your photo.")}

        {:ok, %State.Failed{failure_code: code}} ->
          error_bubble(:pantry, code)

        {:error, reason} ->
          error_bubble(:pantry, reason)
      end
    end)
  end

  # ── recipe (grouped: multi-page recipes stay together) ─────────────────

  @spec ingest_recipe([binary()], ctx()) :: bubble()
  def ingest_recipe(images, _ctx) when is_list(images) and images != [] do
    case Tore.Recipes.extract_from_images(images) do
      {:ok, %{id: id, title: title}} ->
        %{role: :assistant, recipe_card: true, recipe_id: id, title: title}

      {:ok, recipe} when is_map(recipe) ->
        %{
          role: :assistant,
          recipe_card: true,
          recipe_id: recipe[:id] || recipe["id"],
          title: recipe[:title] || recipe["title"]
        }

      {:error, reason} ->
        error_bubble(:recipe, reason)
    end
  end

  # ── fridge → suggestions ───────────────────────────────────────────────

  @spec suggest_from_fridge(binary(), ctx()) :: bubble()
  def suggest_from_fridge(image, _ctx) when is_binary(image) do
    case Tore.Pantry.parse_image(image) do
      {:ok, items} ->
        names = items |> Enum.map(&(&1[:name] || &1["name"])) |> Enum.take(5) |> Enum.join(", ")

        text =
          if names == "" do
            Gettext.dgettext(ToreWeb.Gettext, "default", "I can see your fridge but it looks empty.")
          else
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "I can see %{names} in your fridge. Want me to suggest some recipes?",
              names: names
            )
          end

        %{role: :assistant, text: text}

      {:error, reason} ->
        error_bubble(:fridge, reason)
    end
  end

  # ── URL import ─────────────────────────────────────────────────────────

  @spec import_recipe_from_url(String.t(), String.t() | nil) :: bubble()
  def import_recipe_from_url(url, locale) when is_binary(url) do
    case Tore.Recipes.scrape_from_url(url, locale) do
      {:ok, recipe} ->
        %{role: :assistant, recipe_card: true, recipe_id: recipe.id, title: recipe.title}

      {:error, :not_a_recipe} ->
        %{role: :assistant, text: Gettext.dgettext(ToreWeb.Gettext, "default", "That page doesn't look like a recipe.")}

      {:error, :timeout} ->
        %{role: :assistant, text: Gettext.dgettext(ToreWeb.Gettext, "default", "The site didn't respond. Try again in a moment.")}

      {:error, _reason} ->
        %{role: :assistant, text: Gettext.dgettext(ToreWeb.Gettext, "default", "Couldn't import that URL.")}
    end
  end

  # ── recipe search ──────────────────────────────────────────────────────

  @spec find_recipe(String.t()) :: bubble()
  def find_recipe(query) when is_binary(query) do
    case Recipes.search(query) do
      [] ->
        %{
          role: :assistant,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
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
          text: Gettext.dgettext(ToreWeb.Gettext, "default", "I found: %{titles}.", titles: titles)
        }
    end
  end

  # ── plan slot mutation ─────────────────────────────────────────────────

  @spec set_plan_slot(Date.t(), integer(), integer() | nil, ctx()) ::
          {bubble(), String.t() | nil}
  def set_plan_slot(%Date{} = date, recipe_id, servings, ctx)
      when is_integer(recipe_id) and is_map(ctx) do
    orch_ctx = %{
      household_id: ctx.household_id,
      user_id: ctx[:user_id],
      date: date,
      recipe_id: recipe_id,
      servings: servings || @default_servings
    }

    case Orchestrator.apply_set_plan_slot(orch_ctx) do
      {:ok, %{stream_id: sid, recipe: %{title: title}}} ->
        {%{
           role: :assistant,
           text:
             Gettext.dgettext(
               ToreWeb.Gettext,
               "default",
               "Added %{title} to %{day} %{date}.",
               title: title,
               day: long_day_for(date),
               date: Date.to_iso8601(date)
             ),
           run_stream_id: sid
         }, sid}

      {:error, :recipe_not_found} ->
        {error_bubble(:plan, :recipe_not_found), nil}

      {:error, reason} ->
        {error_bubble(:plan, reason), nil}
    end
  end

  @spec clear_plan_slot(Date.t()) :: bubble()
  def clear_plan_slot(%Date{} = date) do
    plan_id = plan_stream_id_for(date)
    slot_key = slot_key_for(date)

    case Planning.remove_recipe(plan_id, slot_key) do
      {:ok, _events} ->
        %{
          role: :assistant,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "Cleared %{day} %{date}.",
              day: long_day_for(date),
              date: Date.to_iso8601(date)
            )
        }

      {:error, reason} ->
        error_bubble(:plan, reason)
    end
  end

  # ── pantry-driven suggestions ──────────────────────────────────────────

  @spec suggest_meals_from_pantry(pos_integer()) :: bubble()
  def suggest_meals_from_pantry(count) when is_integer(count) and count > 0 do
    today = Date.utc_today()
    week_start = Date.add(today, -(Date.day_of_week(today) - 1))
    plan_id = "plan:#{Date.to_iso8601(week_start)}"
    next_empty = next_empty_slot_key(today)

    case Planning.suggest_recipes_for_slot(plan_id, next_empty, limit: count) do
      {:ok, []} ->
        %{
          role: :assistant,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
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
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "Here's what works with what you have:"
            )
        }

      {:error, reason} ->
        error_bubble(:suggest, reason)
    end
  end

  # ── shopping list ──────────────────────────────────────────────────────

  @spec add_to_shopping_list(String.t(), number() | nil, String.t() | nil, ctx()) :: bubble()
  def add_to_shopping_list(name, quantity, unit, ctx) when is_binary(name) do
    list_id = current_shop_list_id()
    qty = to_decimal(quantity)

    case Shop.add_item(list_id, name, qty, unit, ctx[:user_id]) do
      {:ok, _events} ->
        %{
          role: :assistant,
          shop_link: true,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "Added %{label} to the shopping list.",
              label: shopping_label(name, qty, unit)
            )
        }

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
    list_id = current_shop_list_id()

    case Shop.find_item_fuzzy(list_id, name) do
      {:ok, {id, item}} ->
        case Shop.check_item(list_id, id, ctx[:user_id]) do
          {:ok, _events} ->
            %{
              role: :assistant,
              shop_link: true,
              text:
                Gettext.dgettext(
                  ToreWeb.Gettext,
                  "default",
                  "Checked off %{name}.",
                  name: item.name
                )
            }

          {:error, reason} ->
            error_bubble(:shop, reason)
        end

      {:ambiguous, matches} ->
        names = matches |> Enum.map(fn {_id, it} -> it.name end) |> Enum.join(", ")

        %{
          role: :assistant,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "Multiple shopping items match \"%{q}\": %{names}. Which one?",
              q: name,
              names: names
            )
        }

      {:error, :not_found} ->
        %{
          role: :assistant,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "No shopping item matches \"%{q}\".",
              q: name
            )
        }
    end
  end

  @spec list_shopping_list(boolean()) :: bubble()
  def list_shopping_list(unchecked_only?) when is_boolean(unchecked_only?) do
    list_id = current_shop_list_id()

    case Shop.load_list(list_id) do
      {:ok, %{items: items}} when map_size(items) == 0 ->
        %{
          role: :assistant,
          shop_link: true,
          text: Gettext.dgettext(ToreWeb.Gettext, "default", "Your shopping list is empty.")
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
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "Shopping list (%{n} items):",
              n: length(rendered)
            )
        }

      {:error, reason} ->
        error_bubble(:shop, reason)
    end
  end

  @spec generate_shopping_list_from_plan(Date.t() | nil) :: bubble()
  def generate_shopping_list_from_plan(date \\ nil) do
    target_date = date || Date.utc_today()
    week_start = Date.add(target_date, -(Date.day_of_week(target_date) - 1))
    list_id = "shop_list:#{Date.to_iso8601(week_start)}"
    plan_id = "plan:#{Date.to_iso8601(week_start)}"

    case Planning.load_plan(plan_id) do
      {:ok, state} ->
        recipe_ids =
          state.slots
          |> Map.values()
          |> Enum.map(& &1[:recipe_id])
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        case Shop.build_list(list_id, week_start, recipe_ids) do
          {:ok, _events} ->
            %{
              role: :assistant,
              shop_link: true,
              text:
                Gettext.dgettext(
                  ToreWeb.Gettext,
                  "default",
                  "Built a shopping list for the week of %{date} from %{n} planned recipes.",
                  date: Date.to_iso8601(week_start),
                  n: length(recipe_ids)
                )
            }

          {:error, reason} ->
            error_bubble(:shop, reason)
        end

      {:error, reason} ->
        error_bubble(:plan, reason)
    end
  end

  # ── pantry mutations ───────────────────────────────────────────────────

  @spec add_to_pantry(String.t(), number() | nil, String.t() | nil) :: bubble()
  def add_to_pantry(name, quantity, unit) when is_binary(name) do
    attrs = %{
      name: name,
      quantity: to_decimal(quantity),
      unit: unit,
      provenance: "manual"
    }

    case Pantry.upsert_belief(attrs) do
      {:ok, item, :added, _before} ->
        %{
          role: :assistant,
          text:
            Gettext.dgettext(ToreWeb.Gettext, "default", "Added %{name} to the pantry.",
              name: item.name
            )
        }

      {:ok, item, :bumped, _before} ->
        %{
          role: :assistant,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "Bumped %{name} in the pantry.",
              name: item.name
            )
        }

      {:error, reason} ->
        error_bubble(:pantry, reason)
    end
  end

  @spec remove_from_pantry(String.t()) :: bubble()
  def remove_from_pantry(name) when is_binary(name) do
    case Pantry.find_by_name_fuzzy(name) do
      {:ok, item} ->
        case Pantry.remove_item(item.id) do
          :ok ->
            %{
              role: :assistant,
              text:
                Gettext.dgettext(ToreWeb.Gettext, "default", "Removed %{name} from the pantry.",
                  name: item.name
                )
            }

          {:error, reason} ->
            error_bubble(:pantry, reason)
        end

      {:ambiguous, matches} ->
        names = matches |> Enum.map(& &1.name) |> Enum.join(", ")

        %{
          role: :assistant,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "Multiple pantry items match \"%{q}\": %{names}. Which one?",
              q: name,
              names: names
            )
        }

      {:error, :not_found} ->
        %{
          role: :assistant,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "Nothing in the pantry matches \"%{q}\".",
              q: name
            )
        }
    end
  end

  @spec check_pantry(String.t()) :: bubble()
  def check_pantry(name) when is_binary(name) do
    case Pantry.find_by_name_fuzzy(name) do
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
            Gettext.dgettext(ToreWeb.Gettext, "default", "Yes — %{name}%{qty} is in the pantry.",
              name: item.name,
              qty: qty_str
            )
        }

      {:ambiguous, matches} ->
        names = matches |> Enum.map(& &1.name) |> Enum.join(", ")

        %{
          role: :assistant,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "Several pantry items match: %{names}.",
              names: names
            )
        }

      {:error, :not_found} ->
        %{
          role: :assistant,
          text:
            Gettext.dgettext(ToreWeb.Gettext, "default", "No, %{name} isn't in the pantry.",
              name: name
            )
        }
    end
  end

  # ── plan-slot adjustments ──────────────────────────────────────────────

  @spec mark_recipe_cooked(integer()) :: bubble()
  def mark_recipe_cooked(recipe_id) when is_integer(recipe_id) do
    :ok = Recipes.record_used(recipe_id)

    %{
      role: :assistant,
      text: Gettext.dgettext(ToreWeb.Gettext, "default", "Marked the recipe as cooked tonight.")
    }
  end

  @spec set_plan_servings(Date.t(), pos_integer()) :: bubble()
  def set_plan_servings(%Date{} = date, servings)
      when is_integer(servings) and servings > 0 do
    plan_id = plan_stream_id_for(date)
    slot_key = slot_key_for(date)

    case Planning.set_servings(plan_id, slot_key, servings) do
      {:ok, _events} ->
        %{
          role: :assistant,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "Set servings on %{day} %{date} to %{n}.",
              day: long_day_for(date),
              date: Date.to_iso8601(date),
              n: servings
            )
        }

      {:error, reason} ->
        error_bubble(:plan, reason)
    end
  end

  @spec pin_plan_slot(Date.t(), boolean()) :: bubble()
  def pin_plan_slot(%Date{} = date, pinned?) when is_boolean(pinned?) do
    plan_id = plan_stream_id_for(date)
    slot_key = slot_key_for(date)

    result =
      if pinned? do
        Planning.pin_slot(plan_id, slot_key, true)
      else
        Planning.unpin_slot(plan_id, slot_key)
      end

    case result do
      {:ok, _events} ->
        text =
          if pinned?,
            do:
              Gettext.dgettext(ToreWeb.Gettext, "default", "Pinned %{day} %{date}.",
                day: long_day_for(date),
                date: Date.to_iso8601(date)
              ),
            else:
              Gettext.dgettext(ToreWeb.Gettext, "default", "Unpinned %{day} %{date}.",
                day: long_day_for(date),
                date: Date.to_iso8601(date)
              )

        %{role: :assistant, text: text}

      {:error, reason} ->
        error_bubble(:plan, reason)
    end
  end

  @spec skip_plan_meal(Date.t()) :: bubble()
  def skip_plan_meal(%Date{} = date) do
    plan_id = plan_stream_id_for(date)
    slot_key = slot_key_for(date)

    case Planning.skip_meal(plan_id, slot_key) do
      {:ok, _events} ->
        %{
          role: :assistant,
          text:
            Gettext.dgettext(ToreWeb.Gettext, "default", "Marked %{day} %{date} as skipped.",
              day: long_day_for(date),
              date: Date.to_iso8601(date)
            )
        }

      {:error, reason} ->
        error_bubble(:plan, reason)
    end
  end

  # ── unrecognised image ─────────────────────────────────────────────────

  @spec report_unrecognised_image(String.t() | nil) :: bubble()
  def report_unrecognised_image(suggestion) do
    text =
      case suggestion do
        s when is_binary(s) and s != "" -> s
        _ -> Gettext.dgettext(ToreWeb.Gettext, "default", "I wasn't sure what that photo showed. Could you tell me — is it a receipt, a recipe, or your fridge?")
      end

    %{role: :assistant, text: text}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Race-safe: reserve a stream_id, then try to record the hash. If the
  # unique index trips, another upload already claimed these bytes — return
  # the existing stream_id and never dispatch a duplicate run.
  defp with_dedup(image, ctx, kind, run_fn) do
    hash = Uploads.content_hash(image)
    stream_id = Run.next_stream_id()

    case Uploads.record(ctx.household_id, hash, stream_id, kind) do
      {:ok, ^stream_id} -> run_fn.(stream_id)
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

  defp stash_photo(stream_id, image) do
    case RunPhotos.store(stream_id, image) do
      {:ok, key} ->
        key

      {:error, reason} ->
        require Logger
        Logger.warning("RunPhotos.store failed: #{inspect(reason)} (run continues)")
        nil
    end
  end

  defp review_bubble(:receipt, _sid) do
    %{role: :assistant, review_link: true, text: gettext("I parsed a receipt.")}
  end

  defp review_bubble(:pantry, _sid) do
    %{role: :assistant, review_link: true, text: gettext("I parsed your shelf photo.")}
  end

  defp current_shop_list_id do
    today = Date.utc_today()
    week_start = Date.add(today, -(Date.day_of_week(today) - 1))
    "shop_list:#{Date.to_iso8601(week_start)}"
  end

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

  defp plan_stream_id_for(%Date{} = date) do
    week_start = Date.add(date, -(Date.day_of_week(date) - 1))
    "plan:#{Date.to_iso8601(week_start)}"
  end

  defp slot_key_for(%Date{} = date) do
    day_abbrev = Enum.at(@days, Date.day_of_week(date) - 1)
    "#{day_abbrev}_dinner"
  end

  defp long_day_for(%Date{} = date), do: Enum.at(@day_long, Date.day_of_week(date) - 1)

  defp next_empty_slot_key(%Date{} = today) do
    week_start = Date.add(today, -(Date.day_of_week(today) - 1))
    plan_id = "plan:#{Date.to_iso8601(week_start)}"

    case Planning.load_plan(plan_id) do
      {:ok, state} ->
        today_idx = Date.day_of_week(today) - 1

        Enum.drop(@days, today_idx)
        |> Enum.find_value(fn day ->
          slot_key = "#{day}_dinner"

          case Map.get(state.slots, slot_key) do
            nil -> slot_key
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

    %{
      role: :assistant,
      text:
        Gettext.dgettext(
          ToreWeb.Gettext,
          "default",
          "Something went wrong processing the %{kind} photo.",
          kind: to_string(kind)
        )
    }
  end
end
