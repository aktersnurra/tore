defmodule Tore.Capture.Router do
  @moduledoc """
  One LLM tool-loop per user input at /capture.

  Replaces the old two-step pipeline (image classifier → per-class dispatch)
  with a single multimodal `chat_with_tools` call. The model sees text + all
  uploaded images in one user turn and emits zero-or-more tool calls (plus
  optionally a plain reply). Each tool maps 1:1 to a handler in
  `Tore.Capture.Dispatch`.

  Self-heal: if a handler fails or the model emits no tool calls but has
  images to act on, the failed/empty result is fed back as a tool message
  and the model gets one more shot. Capped at @max_tool_loop_iterations.
  """

  use Gettext, backend: ToreWeb.Gettext

  alias Tore.AiOperations
  alias Tore.Capture.Dispatch
  alias Tore.Harness.Capsules
  alias Tore.Harness.Orchestrator

  alias Tore.Harness.Capsules.{
    HouseholdPreferencesCapsule,
    ActiveInsightsCapsule,
    WeekPlanCapsule,
    PantryBeliefsCapsule
  }

  @chat_capsules [
    HouseholdPreferencesCapsule,
    ActiveInsightsCapsule,
    WeekPlanCapsule,
    PantryBeliefsCapsule
  ]

  @role_preamble """
  You are Tore, a friendly and practical AI cooking and meal planning assistant.
  Help the household plan meals, manage groceries, and make the most of what they have.
  Respond conversationally in the user's language. Be concise and warm.

  When the user uploads images or pastes URLs, call the appropriate tool(s).
  Group multi-page recipes into a single `ingest_recipe` call by listing all
  page indices in `image_indices`. Receipts, shelves, and fridges are
  per-image — emit one tool call per image. If an image isn't recognisable,
  call `report_unrecognised_image` with a helpful suggestion.

  You can — and should — call multiple tools in one turn. Tool results come
  back to you before you reply, so chain freely. Never claim something
  happened without calling the corresponding tool; the tool result is
  ground truth.

  Planning:
    - To slot a known recipe on a day, call `set_plan_slot` with an ISO date
      (use today's date plus the day-of-week math; do not guess).
    - If the user's message contains BOTH a recipe phrase AND a slotting
      verb ("add", "lägg", "put", "schedule", "plan"), call `find_recipe`
      AND `set_plan_slot` in the same turn — use the top result. Do not
      stop after `find_recipe` to confirm; the user already committed.
    - Treat phrases like "the pork recipe" / "min pizza" / "that pasta dish"
      as the same commitment — the user is naming a recipe, not asking you
      to deliberate. Search and slot.
    - "Tomorrow" / "imorgon" / "next Monday" are dates — compute them from
      today's date in the system prompt; do not ask the user to clarify.
    - Only pause to ask the user when `find_recipe` returns no match, or
      when the user's phrasing is genuinely browsing ("what pizzas do I
      have?") rather than committing.
    - To clear a day, call `clear_plan_slot`.
    - When the user asks what to cook, call `suggest_meals_from_pantry`.
    - Adjust portions with `set_plan_servings`; pin/unpin with `pin_plan_slot`.
      Mark a recipe as cooked tonight with `mark_recipe_cooked` (this is what
      teaches the rotation to deprioritise it).
    - "We're eating out Tuesday" / "vi äter ute på fredag" → `mark_eating_out`,
      even if the day has no meal. If they later say what it cost, call it again
      for that day with the amount. Use `skip_plan_meal` only when they're not
      having dinner at all and aren't eating out.

  Shopping list (always current week):
    - "Add X to the shopping list" → `add_to_shopping_list`.
    - "I bought X" / "got the milk" → `check_off_shopping_item`.
    - "What's on the shopping list?" → `list_shopping_list`.
    - "Make a shopping list for this week" → `generate_shopping_list_from_plan`.

  Pantry:
    - "I bought 2kg flour" / "we got more milk" → `add_to_pantry`.
    - "We're out of X" / "finished the eggs" → `remove_from_pantry`.
    - "Do I have X?" — the PantryBeliefs capsule already shows the pantry
      in your system prompt, so answer from that. Only call `check_pantry`
      if the capsule looks truncated.

  When there is nothing actionable, reply with plain text.
  """

  @max_tool_loop_iterations 5

  @type ctx :: %{
          required(:household_id) => integer(),
          optional(:user_id) => integer() | nil
        }
  @type reply :: map()

  @spec route(String.t(), [binary()], ctx(), [map()]) :: {:ok, [reply()]} | {:error, term()}
  def route(text, images, ctx, history \\ [])
      when is_binary(text) and is_list(images) and is_map(ctx) and is_list(history) do
    correlation_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    AiOperations.log(%{
      run_stream_id: correlation_id,
      kind: "capture_route",
      payload: %{
        "text" => text,
        "image_count" => length(images),
        "history_turns" => length(history)
      }
    })

    system =
      [@role_preamble, date_line(), Capsules.compose(@chat_capsules, chat_ctx(ctx))]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    history_messages = history_to_messages(history)
    user_message = build_multimodal_user(text, images)

    {parent_sid, turn_ctx} = open_turn_run(ctx)

    result =
      loop(
        system,
        history_messages ++ [user_message],
        [],
        [],
        images,
        turn_ctx,
        correlation_id,
        0
      )

    close_turn_run(parent_sid, result)
  end

  defp open_turn_run(ctx) do
    case Orchestrator.start_turn(ctx) do
      {:ok, sid} -> {sid, Map.put(ctx, :parent_stream_id, sid)}
      _ -> {nil, ctx}
    end
  end

  defp close_turn_run(nil, result), do: drop_sids(result)

  defp close_turn_run(parent_sid, {:ok, bubbles, child_sids}) do
    _ = Orchestrator.end_turn(parent_sid, child_sids)
    {:ok, bubbles}
  end

  defp close_turn_run(parent_sid, {:error, _} = err) do
    _ = Orchestrator.end_turn(parent_sid, [])
    err
  end

  defp drop_sids({:ok, bubbles, _sids}), do: {:ok, bubbles}
  defp drop_sids(other), do: other

  # Convert the LiveView's bubble list into OpenAI-shape chat turns. We
  # only carry text — images from past turns are dropped (the bytes aren't
  # in our state and weren't part of the persisted message either way).
  defp history_to_messages(history) do
    Enum.flat_map(history, fn
      %{role: :user, text: t} when is_binary(t) and t != "" ->
        [%{role: "user", content: t}]

      %{role: :assistant, text: t} when is_binary(t) and t != "" ->
        [%{role: "assistant", content: t}]

      _ ->
        []
    end)
  end

  # ── tool-loop ──────────────────────────────────────────────────────────
  #
  # `bubbles_acc` accumulates user-facing bubbles across iterations so that
  # when the model finally replies in plain text we can show the full
  # tool-call trail (e.g. "I found X" + "Added X to Friday" + final reply).

  defp loop(_system, _messages, bubbles_acc, sids_acc, _images, _ctx, _cid, iter)
       when iter > @max_tool_loop_iterations do
    {:ok, bubbles_acc ++ [%{role: :assistant, text: fallback_text()}], sids_acc}
  end

  defp loop(system, messages, bubbles_acc, sids_acc, images, ctx, correlation_id, iter) do
    # tool_choice is "auto" after the first turn: once the model has tool
    # results it must be free to reply in plain text, otherwise it would
    # be forced to keep calling tools forever.
    choice = if iter == 0, do: tool_choice(images), else: "auto"

    case Tore.LLM.chat_with_tools(system, messages, tool_catalogue(), tool_choice: choice) do
      {:ok, {:message, text}, _usage} ->
        {:ok, bubbles_acc ++ [%{role: :assistant, text: text}], sids_acc}

      {:ok, {:tool_calls, calls}, _usage} ->
        results = dispatch_calls_with_results(calls, images, ctx)
        new_bubbles = Enum.map(results, & &1.bubble)
        new_sids = Enum.flat_map(results, &Map.get(&1, :child_sids, []))

        if iter == @max_tool_loop_iterations do
          {:ok, bubbles_acc ++ new_bubbles, sids_acc ++ new_sids}
        else
          assistant_msg = %{role: "assistant", content: nil, tool_calls: raw_tool_calls(calls)}
          tool_msgs = Enum.map(results, &tool_result_message/1)

          loop(
            system,
            messages ++ [assistant_msg] ++ tool_msgs,
            bubbles_acc ++ new_bubbles,
            sids_acc ++ new_sids,
            images,
            ctx,
            correlation_id,
            iter + 1
          )
        end

      {:error, reason} ->
        require Logger
        Logger.warning("Capture.Router LLM call failed: #{inspect(reason)}")
        {:ok, bubbles_acc ++ [%{role: :assistant, text: fallback_text()}], sids_acc}
    end
  end

  # ── tool dispatch ──────────────────────────────────────────────────────

  defp dispatch_calls_with_results(calls, images, ctx) do
    image_count = length(images)

    Enum.map(calls, fn call ->
      case run_call(call, images, image_count, ctx) do
        {:ok, more_bubbles} ->
          %{
            tool_call: call,
            status: :ok,
            bubble: List.first(more_bubbles) || empty_bubble(),
            child_sids: []
          }

        {:ok, more_bubbles, sids} ->
          %{
            tool_call: call,
            status: :ok,
            bubble: List.first(more_bubbles) || empty_bubble(),
            child_sids: sids
          }

        {:error, reason} ->
          %{
            tool_call: call,
            status: :error,
            reason: reason,
            bubble: error_bubble_from_reason(reason),
            child_sids: []
          }
      end
    end)
  end

  defp empty_bubble, do: %{role: :assistant, text: ""}

  defp error_bubble_from_reason(reason) do
    %{role: :assistant, text: "Tool failed: #{inspect(reason)}"}
  end

  defp run_call(%{name: "ingest_receipt", args: args}, images, image_count, ctx) do
    with {:ok, indices} <- fetch_indices(args, image_count) do
      bubbles =
        Enum.map(indices, fn i -> Dispatch.ingest_receipt(Enum.at(images, i - 1), ctx) end)

      {:ok, bubbles}
    end
  end

  defp run_call(%{name: "ingest_recipe", args: args}, images, image_count, ctx) do
    with {:ok, indices} <- fetch_indices(args, image_count) do
      grouped = Enum.map(indices, &Enum.at(images, &1 - 1))
      {:ok, [Dispatch.ingest_recipe(grouped, ctx)]}
    end
  end

  defp run_call(%{name: "update_pantry_from_shelf", args: args}, images, image_count, ctx) do
    with {:ok, indices} <- fetch_indices(args, image_count) do
      bubbles =
        Enum.map(indices, fn i ->
          Dispatch.update_pantry_from_shelf(Enum.at(images, i - 1), ctx)
        end)

      {:ok, bubbles}
    end
  end

  defp run_call(%{name: "suggest_from_fridge", args: args}, images, image_count, ctx) do
    with {:ok, indices} <- fetch_indices(args, image_count) do
      bubbles =
        Enum.map(indices, fn i -> Dispatch.suggest_from_fridge(Enum.at(images, i - 1), ctx) end)

      {:ok, bubbles}
    end
  end

  defp run_call(%{name: "import_recipe_from_url", args: %{"url" => url}}, _images, _count, ctx)
       when is_binary(url) do
    {:ok, [Dispatch.import_recipe_from_url(url, ctx)]}
  end

  defp run_call(%{name: "report_unrecognised_image", args: args}, _images, _count, _ctx) do
    {:ok, [Dispatch.report_unrecognised_image(args["suggestion"])]}
  end

  defp run_call(%{name: "find_recipe", args: %{"query" => q}}, _images, _count, ctx)
       when is_binary(q) do
    {:ok, [Dispatch.find_recipe(q, ctx)]}
  end

  defp run_call(%{name: "set_plan_slot", args: args}, _images, _count, ctx) do
    with {:ok, date} <- parse_iso_date(args["date"]),
         {:ok, recipe_id} <- fetch_recipe_id(args) do
      {bubble, child_sid} = Dispatch.set_plan_slot(date, recipe_id, args["servings"], ctx)
      sids = if child_sid, do: [child_sid], else: []
      {:ok, [bubble], sids}
    end
  end

  defp run_call(%{name: "clear_plan_slot", args: %{"date" => date_str}}, _images, _count, ctx) do
    with {:ok, date} <- parse_iso_date(date_str) do
      {:ok, [Dispatch.clear_plan_slot(date, ctx)]}
    end
  end

  defp run_call(%{name: "suggest_meals_from_pantry", args: args}, _images, _count, ctx) do
    count = args["count"] || 4
    {:ok, [Dispatch.suggest_meals_from_pantry(count, ctx)]}
  end

  defp run_call(%{name: "add_to_shopping_list", args: args}, _images, _count, ctx)
       when is_binary(:erlang.map_get("name", args)) do
    {:ok, [Dispatch.add_to_shopping_list(args["name"], args["quantity"], args["unit"], ctx)]}
  end

  defp run_call(%{name: "check_off_shopping_item", args: %{"name" => name}}, _images, _count, ctx)
       when is_binary(name) do
    {:ok, [Dispatch.check_off_shopping_item(name, ctx)]}
  end

  defp run_call(%{name: "list_shopping_list", args: args}, _images, _count, ctx) do
    {:ok, [Dispatch.list_shopping_list(args["unchecked_only"] == true, ctx)]}
  end

  defp run_call(%{name: "generate_shopping_list_from_plan", args: args}, _images, _count, ctx) do
    case args["date"] do
      nil ->
        {:ok, [Dispatch.generate_shopping_list_from_plan(nil, ctx)]}

      str when is_binary(str) ->
        with {:ok, date} <- parse_iso_date(str) do
          {:ok, [Dispatch.generate_shopping_list_from_plan(date, ctx)]}
        end
    end
  end

  defp run_call(%{name: "add_to_pantry", args: args}, _images, _count, ctx)
       when is_binary(:erlang.map_get("name", args)) do
    {:ok, [Dispatch.add_to_pantry(args["name"], args["quantity"], args["unit"], ctx)]}
  end

  defp run_call(%{name: "remove_from_pantry", args: %{"name" => name}}, _images, _count, ctx)
       when is_binary(name) do
    {:ok, [Dispatch.remove_from_pantry(name, ctx)]}
  end

  defp run_call(%{name: "check_pantry", args: %{"name" => name}}, _images, _count, ctx)
       when is_binary(name) do
    {:ok, [Dispatch.check_pantry(name, ctx)]}
  end

  defp run_call(%{name: "mark_recipe_cooked", args: %{"recipe_id" => id}}, _images, _count, ctx)
       when is_integer(id) do
    {:ok, [Dispatch.mark_recipe_cooked(id, ctx)]}
  end

  defp run_call(%{name: "set_plan_servings", args: args}, _images, _count, ctx) do
    with {:ok, date} <- parse_iso_date(args["date"]),
         servings when is_integer(servings) and servings > 0 <- args["servings"] do
      {:ok, [Dispatch.set_plan_servings(date, servings, ctx)]}
    else
      _ -> {:error, :invalid_servings}
    end
  end

  defp run_call(%{name: "pin_plan_slot", args: args}, _images, _count, ctx) do
    with {:ok, date} <- parse_iso_date(args["date"]) do
      pinned? = args["pinned"] != false
      {:ok, [Dispatch.pin_plan_slot(date, pinned?, ctx)]}
    end
  end

  defp run_call(%{name: "skip_plan_meal", args: %{"date" => date_str}}, _images, _count, ctx) do
    with {:ok, date} <- parse_iso_date(date_str) do
      {:ok, [Dispatch.skip_plan_meal(date, ctx)]}
    end
  end

  defp run_call(%{name: "mark_eating_out", args: args}, _images, _count, ctx) do
    with {:ok, date} <- parse_iso_date(args["date"]) do
      attrs = %{description: args["place"], total_amount: args["amount"]}
      {:ok, [Dispatch.mark_eating_out(date, attrs, ctx)]}
    end
  end

  defp run_call(%{name: name}, _images, _count, _ctx) do
    {:error, {:unknown_tool, name}}
  end

  defp parse_iso_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, {:invalid_date, str}}
    end
  end

  defp parse_iso_date(_), do: {:error, :missing_date}

  defp fetch_recipe_id(%{"recipe_id" => id}) when is_integer(id), do: {:ok, id}
  defp fetch_recipe_id(_), do: {:error, :missing_recipe_id}

  defp fetch_indices(%{"image_indices" => indices}, image_count)
       when is_list(indices) and indices != [] do
    validated =
      Enum.reduce_while(indices, [], fn
        i, acc when is_integer(i) and i >= 1 and i <= image_count -> {:cont, [i | acc]}
        i, _acc -> {:halt, {:invalid_index, i}}
      end)

    case validated do
      {:invalid_index, i} -> {:error, {:image_index_out_of_range, i, image_count}}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp fetch_indices(_, _), do: {:error, :missing_image_indices}

  # ── tool catalogue (OpenAI function schema) ────────────────────────────

  defp tool_catalogue do
    [
      tool(
        "ingest_receipt",
        "Parse a store receipt and surface an editable card in the inbox.",
        image_indices_schema()
      ),
      tool(
        "ingest_recipe",
        "Extract a recipe from one or more photos (group multi-page recipes by listing all page indices).",
        image_indices_schema()
      ),
      tool(
        "update_pantry_from_shelf",
        "Read pantry items from a shelf or counter photo and update the household's pantry beliefs.",
        image_indices_schema()
      ),
      tool(
        "suggest_from_fridge",
        "Read fridge contents from a photo and suggest recipes from what's visible.",
        image_indices_schema()
      ),
      tool(
        "import_recipe_from_url",
        "Scrape a recipe from a URL the user pasted.",
        %{
          type: "object",
          properties: %{url: %{type: "string", description: "The full http(s) URL to scrape."}},
          required: ["url"],
          additionalProperties: false
        }
      ),
      tool(
        "report_unrecognised_image",
        "Use when an image can't be recognised — provide a short suggestion of what the user could try.",
        %{
          type: "object",
          properties: %{
            suggestion: %{
              type: "string",
              description: "Short user-facing suggestion (one sentence)."
            }
          },
          required: ["suggestion"],
          additionalProperties: false
        }
      ),
      tool(
        "find_recipe",
        "Search the recipe library by title or ingredient. Use this before set_plan_slot when the user names a recipe by phrase rather than id.",
        %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Free-text title or ingredient query."}
          },
          required: ["query"],
          additionalProperties: false
        }
      ),
      tool(
        "set_plan_slot",
        "Assign a known recipe to a specific date's dinner slot. Date must be ISO yyyy-mm-dd (compute it yourself from today's date and the day-of-week the user mentioned).",
        %{
          type: "object",
          properties: %{
            date: %{type: "string", description: "ISO 8601 date (yyyy-mm-dd)."},
            recipe_id: %{
              type: "integer",
              description: "The recipe's numeric id from find_recipe."
            },
            servings: %{
              type: "integer",
              description: "Optional servings; defaults to 4 if omitted."
            }
          },
          required: ["date", "recipe_id"],
          additionalProperties: false
        }
      ),
      tool(
        "clear_plan_slot",
        "Remove any recipe assigned to a specific date's dinner slot.",
        %{
          type: "object",
          properties: %{
            date: %{type: "string", description: "ISO 8601 date (yyyy-mm-dd)."}
          },
          required: ["date"],
          additionalProperties: false
        }
      ),
      tool(
        "suggest_meals_from_pantry",
        "Return up to `count` recipe suggestions ranked by what's in the pantry, on sale, and not recently cooked. Use when the user asks what to cook with no specific recipe in mind.",
        %{
          type: "object",
          properties: %{
            count: %{type: "integer", description: "How many suggestions (1-4)."}
          },
          required: ["count"],
          additionalProperties: false
        }
      ),

      # ── Shopping list ───────────────────────────────────────────────
      tool(
        "add_to_shopping_list",
        "Add a single ad-hoc item to the current week's shopping list. Use when the user says 'add X to the shopping list' or similar.",
        %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Item name as the user said it."},
            quantity: %{type: ["number", "null"], description: "Optional quantity."},
            unit: %{type: ["string", "null"], description: "Optional unit (l, kg, st, pcs…)."}
          },
          required: ["name"],
          additionalProperties: false
        }
      ),
      tool(
        "check_off_shopping_item",
        "Check an item off the current week's shopping list by fuzzy name match. Use when the user says 'I got the milk' / 'I bought eggs'.",
        %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Item to check off (free text)."}
          },
          required: ["name"],
          additionalProperties: false
        }
      ),
      tool(
        "list_shopping_list",
        "Return the current week's shopping list. Use when the user asks 'what's on the shopping list?' or 'what do I still need to buy?'.",
        %{
          type: "object",
          properties: %{
            unchecked_only: %{
              type: "boolean",
              description: "True to show only items still to buy; false for the whole list."
            }
          },
          required: ["unchecked_only"],
          additionalProperties: false
        }
      ),
      tool(
        "generate_shopping_list_from_plan",
        "Build a shopping list for the week from the planned recipes. Overwrites any existing list for that week. Use when the user says 'make a shopping list for this week'.",
        %{
          type: "object",
          properties: %{
            date: %{
              type: ["string", "null"],
              description: "Any ISO 8601 date in the target week. Null means current week."
            }
          },
          required: ["date"],
          additionalProperties: false
        }
      ),

      # ── Pantry ──────────────────────────────────────────────────────
      tool(
        "add_to_pantry",
        "Add (or bump) an item in the pantry. Use when the user says 'I just bought 2kg flour' or 'we got more milk'.",
        %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Item name."},
            quantity: %{type: ["number", "null"], description: "Optional quantity."},
            unit: %{type: ["string", "null"], description: "Optional unit."}
          },
          required: ["name"],
          additionalProperties: false
        }
      ),
      tool(
        "remove_from_pantry",
        "Remove an item from the pantry by fuzzy name match. Use when the user says 'we're out of X' or 'finished the milk'.",
        %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Item to remove (free text)."}
          },
          required: ["name"],
          additionalProperties: false
        }
      ),
      tool(
        "check_pantry",
        "Check whether an item is in the pantry. Use only when the PantryBeliefs capsule in the system prompt doesn't already make this obvious.",
        %{
          type: "object",
          properties: %{
            name: %{type: "string", description: "Item to check (free text)."}
          },
          required: ["name"],
          additionalProperties: false
        }
      ),

      # ── Plan adjustments ───────────────────────────────────────────
      tool(
        "mark_recipe_cooked",
        "Mark a recipe as cooked tonight (bumps last_used_at so rotation deprioritises it). Use when the user says 'we made the chili tonight'.",
        %{
          type: "object",
          properties: %{
            recipe_id: %{type: "integer", description: "Recipe id from find_recipe or the plan."}
          },
          required: ["recipe_id"],
          additionalProperties: false
        }
      ),
      tool(
        "set_plan_servings",
        "Adjust servings on a specific date's dinner slot.",
        %{
          type: "object",
          properties: %{
            date: %{type: "string", description: "ISO 8601 date (yyyy-mm-dd)."},
            servings: %{type: "integer", description: "Desired servings (>= 1)."}
          },
          required: ["date", "servings"],
          additionalProperties: false
        }
      ),
      tool(
        "pin_plan_slot",
        "Pin or unpin a slot so re-planning won't change it. Use when the user says 'don't change Friday'.",
        %{
          type: "object",
          properties: %{
            date: %{type: "string", description: "ISO 8601 date (yyyy-mm-dd)."},
            pinned: %{type: "boolean", description: "True to pin, false to unpin."}
          },
          required: ["date", "pinned"],
          additionalProperties: false
        }
      ),
      tool(
        "skip_plan_meal",
        "Mark a day's dinner slot as skipped, for when there's no dinner and no eating out. Fails if the day has no meal.",
        %{
          type: "object",
          properties: %{
            date: %{type: "string", description: "ISO 8601 date (yyyy-mm-dd)."}
          },
          required: ["date"],
          additionalProperties: false
        }
      ),
      tool(
        "mark_eating_out",
        "Mark a day as eating out. Cancels any recipe that day and works on an empty day. Call again to add the place or amount later.",
        %{
          type: "object",
          properties: %{
            date: %{type: "string", description: "ISO 8601 date (yyyy-mm-dd)."},
            place: %{type: ["string", "null"], description: "Optional restaurant or occasion."},
            amount: %{type: ["number", "null"], description: "Optional total paid, in kr."}
          },
          required: ["date"],
          additionalProperties: false
        }
      )
    ]
  end

  defp tool(name, description, parameters) do
    %{
      type: "function",
      function: %{name: name, description: description, parameters: parameters}
    }
  end

  defp image_indices_schema do
    %{
      type: "object",
      properties: %{
        image_indices: %{
          type: "array",
          items: %{type: "integer", minimum: 1},
          description: "1-based indices into the user's uploaded images."
        }
      },
      required: ["image_indices"],
      additionalProperties: false
    }
  end

  defp tool_choice([]), do: "auto"
  defp tool_choice(_images), do: "required"

  # ── message construction ───────────────────────────────────────────────

  defp build_multimodal_user(text, []) do
    %{role: "user", content: text}
  end

  defp build_multimodal_user(text, images) do
    parts =
      [%{type: "text", text: text_with_image_index(text, length(images))}] ++
        Enum.map(images, fn bin ->
          %{type: "image_url", image_url: %{url: "data:image/jpeg;base64,#{Base.encode64(bin)}"}}
        end)

    %{role: "user", content: parts}
  end

  defp text_with_image_index(text, count) do
    annotation =
      case count do
        1 -> "[Attached: 1 image, referred to as image 1.]"
        n -> "[Attached: #{n} images, referred to as images 1..#{n} in order.]"
      end

    if String.trim(text) == "", do: annotation, else: "#{text}\n\n#{annotation}"
  end

  defp raw_tool_calls(calls) do
    Enum.map(calls, fn %{id: id, name: name, args: args} ->
      %{
        id: id,
        type: "function",
        function: %{name: name, arguments: Jason.encode!(args)}
      }
    end)
  end

  defp tool_result_message(%{tool_call: %{id: id, name: name}, status: :ok, bubble: bubble}) do
    %{
      role: "tool",
      tool_call_id: id,
      name: name,
      content: Jason.encode!(tool_result_payload(name, bubble))
    }
  end

  defp tool_result_message(%{tool_call: %{id: id, name: name}, status: :error, reason: reason}) do
    %{
      role: "tool",
      tool_call_id: id,
      name: name,
      content: "error: #{inspect(reason)}. Try a different tool or reply in plain text."
    }
  end

  # Strip the user-facing bubble fields down to what the *model* needs to
  # see. For tools that return data the model must thread (find_recipe →
  # set_plan_slot), surface ids & titles. For mutations, confirm success.
  defp tool_result_payload("find_recipe", bubble) do
    %{
      status: "ok",
      top_recipe_id: bubble[:top_recipe_id],
      top_title: bubble[:top_title],
      candidate_ids: bubble[:candidate_ids] || [],
      message: bubble[:text]
    }
  end

  defp tool_result_payload("list_shopping_list", bubble) do
    %{
      status: "ok",
      items: bubble[:shopping_items] || [],
      message: bubble[:text]
    }
  end

  defp tool_result_payload(_name, bubble) do
    %{status: "ok", message: bubble[:text] || ""}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp date_line do
    "Today is #{Calendar.strftime(Date.utc_today(), "%A, %B %-d, %Y")}."
  end

  defp chat_ctx(ctx) do
    today = Date.utc_today()
    week_start = Date.add(today, -(Date.day_of_week(today) - 1))

    %{
      household_id: ctx.household_id,
      plan_stream_id: "plan:#{Date.to_iso8601(week_start)}",
      week_start: week_start
    }
  end

  defp fallback_text do
    gettext("Sorry, I couldn't process that. Please try again.")
  end
end
