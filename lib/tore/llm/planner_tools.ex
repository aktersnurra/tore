defmodule Tore.LLM.PlannerTools do
  @moduledoc """
  Tool catalog for the planner agent. Each tool's `run` function takes
  string-keyed args, a `ctx` map (must include :plan_id and :week_start),
  and a `working_plan` State. Action tools are pure proposals: they call
  the Decider against the in-memory working_plan and return
  `{:ok, result, events, next_plan}` — nothing is persisted. Read tools
  and `ask_user` return `{:ok, result, [], working_plan}`.
  """

  alias Tore.LLM.{Tool, Prompts}
  alias Tore.SpendGuard
  alias Tore.Planning
  alias Tore.Planning.{Commands, Decider, State}
  alias Tore.Harness.{Handles, Resolvers}

  @slot_key %{type: "string", description: "Slot identifier like \"mon_dinner\""}
  @rationale %{
    type: "string",
    description: "One short clause explaining why you are making this change."
  }

  @spec all() :: [Tool.t()]
  def all do
    [
      assign_recipe(),
      swap_recipe(),
      skip_meal(),
      mark_leftover(),
      set_servings(),
      remove_recipe(),
      ask_user(),
      search_recipes(),
      resolve_recipe(),
      resolve_slot(),
      pantry_snapshot(),
      active_deals(),
      find_recipe_web(),
      import_recipe_from_web(),
      generate_recipe_variant()
    ]
  end

  # ---------- Action tools ----------

  defp assign_recipe do
    %Tool{
      name: "assign_recipe",
      description: "Place a recipe in a slot. Sets servings.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{
          slot_key: @slot_key,
          recipe_ref: %{
            type: "string",
            description: "a ref returned by search_recipes or resolve_recipe"
          },
          servings: %{type: "integer", minimum: 1},
          rationale: @rationale
        },
        required: ["slot_key", "recipe_ref", "servings", "rationale"]
      },
      run: fn args, ctx, plan ->
        cmd = %Commands.AssignRecipe{
          slot_key: args["slot_key"],
          recipe_id: args["recipe_id"],
          servings: args["servings"]
        }

        propose(cmd, plan, %{ok: true, label: recipe_title(ctx, args["recipe_id"])})
      end
    }
  end

  defp swap_recipe do
    %Tool{
      name: "swap_recipe",
      description: "Atomically swap whatever is in from_slot_key and to_slot_key. No data loss.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{
          from_slot_key: @slot_key,
          to_slot_key: @slot_key,
          rationale: @rationale
        },
        required: ["from_slot_key", "to_slot_key", "rationale"]
      },
      run: fn args, ctx, plan ->
        with :ok <- not_eating_out(plan, args["from_slot_key"]),
             :ok <- not_eating_out(plan, args["to_slot_key"]),
             {:ok, events, next} <-
               Planning.swap_events(plan, args["from_slot_key"], args["to_slot_key"]) do
          to_recipe_id = get_in(next.slots, [args["to_slot_key"], :recipe_id])

          {:ok, %{ok: true, label: recipe_title(ctx, to_recipe_id)}, events, next}
        end
      end
    }
  end

  defp skip_meal do
    %Tool{
      name: "skip_meal",
      description: "Mark a slot as skipped. Neutral; no warning, no cascade.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{slot_key: @slot_key, rationale: @rationale},
        required: ["slot_key", "rationale"]
      },
      run: fn args, _ctx, plan ->
        propose(%Commands.SkipMeal{slot_key: args["slot_key"]}, plan, %{ok: true})
      end
    }
  end

  defp mark_leftover do
    %Tool{
      name: "mark_leftover",
      description: "Mark a slot as leftovers from a prior meal.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{slot_key: @slot_key, rationale: @rationale},
        required: ["slot_key", "rationale"]
      },
      run: fn args, _ctx, plan ->
        propose(%Commands.MarkLeftover{slot_key: args["slot_key"]}, plan, %{ok: true})
      end
    }
  end

  defp set_servings do
    %Tool{
      name: "set_servings",
      description: "Change servings for a slot's recipe.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{
          slot_key: @slot_key,
          servings: %{type: "integer", minimum: 1},
          rationale: @rationale
        },
        required: ["slot_key", "servings", "rationale"]
      },
      run: fn args, _ctx, plan ->
        propose(
          %Commands.SetServings{slot_key: args["slot_key"], servings: args["servings"]},
          plan,
          %{ok: true}
        )
      end
    }
  end

  defp remove_recipe do
    %Tool{
      name: "remove_recipe",
      description: "Clear a slot.",
      kind: :action,
      parameters: %{
        type: "object",
        properties: %{slot_key: @slot_key, rationale: @rationale},
        required: ["slot_key", "rationale"]
      },
      run: fn args, _ctx, plan ->
        propose(%Commands.RemoveRecipe{slot_key: args["slot_key"]}, plan, %{ok: true})
      end
    }
  end

  defp ask_user do
    %Tool{
      name: "ask_user",
      description:
        "Surface a clarifying question to the user instead of guessing. Terminal: the agent stops the loop and shows the question.",
      kind: :read,
      parameters: %{
        type: "object",
        properties: %{question: %{type: "string"}},
        required: ["question"]
      },
      run: fn args, _ctx, plan -> {:ok, %{ask_user: args["question"]}, [], plan} end
    }
  end

  # ---------- Read tools ----------

  defp search_recipes do
    %Tool{
      name: "search_recipes",
      description:
        "Search the recipe catalog. Combine query text and max cooking time, plus an optional limit. Use this before assigning a recipe so you have a ref to pass to assign_recipe.",
      kind: :read,
      parameters: %{
        type: "object",
        properties: %{
          query: %{type: "string", description: "Free-text search across titles and ingredients"},
          max_minutes: %{type: "integer", minimum: 1},
          limit: %{type: "integer", minimum: 1, maximum: 25}
        },
        required: []
      },
      run: fn args, ctx, plan ->
        limit = Map.get(args, "limit", 8)
        max_minutes = args["max_minutes"]

        base =
          case args["query"] do
            q when is_binary(q) and byte_size(q) > 0 ->
              results = Tore.Recipes.search(scope(ctx), q)

              if is_integer(max_minutes) do
                Enum.filter(results, &recipe_under_minutes?(&1, max_minutes))
              else
                results
              end

            _ ->
              opts = if is_integer(max_minutes), do: [max_minutes: max_minutes], else: []
              Tore.Recipes.list(scope(ctx), opts)
          end

        handles =
          base
          |> Enum.take(limit)
          |> Enum.map(&Handles.recipe(&1.id, &1.title, :search_recipes, 1.0))

        result =
          base
          |> Enum.take(limit)
          |> Enum.zip(handles)
          |> Enum.map(fn {r, h} -> Map.put(summarise_recipe(r), :ref, h.ref) end)

        {:ok, %{recipes: result, __handles__: handles}, [], plan}
      end
    }
  end

  defp resolve_recipe do
    %Tool{
      name: "resolve_recipe",
      description:
        "Resolve a natural-language recipe reference to a ref. Use this (or search_recipes) before assign_recipe.",
      kind: :read,
      parameters: %{
        type: "object",
        properties: %{query: %{type: "string"}},
        required: ["query"]
      },
      run: fn args, ctx, plan ->
        case Resolvers.resolve_recipe(scope(ctx), args["query"]) do
          {:ok, h} ->
            {:ok,
             %{
               match: %{ref: h.ref, label: h.label, confidence: h.confidence},
               __handles__: [h]
             }, [], plan}

          {:ambiguous, hs} ->
            {:ok,
             %{
               ambiguous:
                 Enum.map(hs, &%{ref: &1.ref, label: &1.label, confidence: &1.confidence}),
               note: "multiple matches — ask_user or refine",
               __handles__: hs
             }, [], plan}

          :not_found ->
            {:ok, %{not_found: true}, [], plan}
        end
      end
    }
  end

  defp resolve_slot do
    %Tool{
      name: "resolve_slot",
      description:
        "Resolve a natural-language day/slot reference (in English — e.g. \"tonight\", " <>
          "\"tuesday\", \"the salmon dinner\") to a structural slot_key. " <>
          "Use before slot-targeting actions when the user did not name a slot key.",
      kind: :read,
      parameters: %{
        type: "object",
        properties: %{reference: %{type: "string"}},
        required: ["reference"]
      },
      run: fn args, ctx, plan ->
        slots =
          Map.new(plan.slots, fn {k, slot} ->
            {k, slot.recipe_id && recipe_title(ctx, slot.recipe_id)}
          end)

        today = Map.get(ctx, :today, Date.utc_today())

        result =
          case Resolvers.resolve_slot(args["reference"], slots: slots, today: today) do
            {:ok, res} ->
              res

            {:ambiguous, candidates} ->
              %{ambiguous: candidates, note: "multiple matches — ask_user or refine"}

            :not_found ->
              %{not_found: true}
          end

        {:ok, result, [], plan}
      end
    }
  end

  defp pantry_snapshot do
    %Tool{
      name: "pantry_snapshot",
      description:
        "Approximate pantry inventory. Treat results as inexact — items may be missing or stale. Use before suggesting recipes that depend on specific ingredients. Prefer recipes that use items whose expires_on is soon. Don't count items past expires_on as available.",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _args, ctx, plan ->
        now = DateTime.utc_now()

        items =
          Tore.Pantry.list_inventory(scope(ctx))
          |> Enum.map(fn it ->
            %{
              id: it.id,
              name: it.name,
              quantity: it.quantity && Decimal.to_string(it.quantity),
              unit: it.unit,
              category: it.category,
              expires_on: it.expires_at && Date.to_iso8601(it.expires_at),
              belief: Tore.Pantry.PantryItem.effective_belief(it, now)
            }
          end)

        {:ok, %{items: items}, [], plan}
      end
    }
  end

  defp active_deals do
    %Tool{
      name: "active_deals",
      description:
        "Currently active store deals across configured stores. Use before suggesting recipes that align with current promotions.",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _args, _ctx, plan ->
        deals =
          Tore.Deals.list_current()
          |> Enum.map(fn d ->
            %{
              id: d.id,
              product_name: d.product_name,
              brand: d.brand,
              store: d.store,
              chain: d.chain,
              price: d.price && Decimal.to_string(d.price),
              price_unit: d.price_unit
            }
          end)

        {:ok, %{deals: deals}, [], plan}
      end
    }
  end

  defp find_recipe_web do
    %Tool{
      name: "find_recipe_web",
      description:
        "Search the web for recipe pages when the local catalog has nothing suitable. " <>
          "Returns candidate titles and urls only — pick one and import it; never write the recipe yourself.",
      kind: :read,
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "What kind of recipe to look for, e.g. \"quick weeknight ramen\""
          }
        },
        required: ["query"]
      },
      run: fn args, ctx, plan ->
        case SpendGuard.allow?(:recipe_web_search) do
          :ok -> search_web(ctx, args["query"], plan)
          {:error, _reason} -> {:ok, %{unavailable: true, reason: guard_message()}, [], plan}
        end
      end
    }
  end

  defp search_web(ctx, query, plan) do
    {system, user} = Prompts.find_recipe_web(query, household_locale(ctx))

    case Tore.LLM.web_search(system, user, response_format: Prompts.web_candidates_json_schema()) do
      {:ok, payload, usage} ->
        SpendGuard.log_usage(:recipe_web_search, usage)
        {:ok, candidates_result(payload["candidates"] || []), [], plan}

      {:error, _} = err ->
        err
    end
  end

  defp candidates_result([]), do: %{candidates: [], not_found: true}

  defp candidates_result(candidates) do
    %{candidates: Enum.map(candidates, &%{title: &1["title"], url: &1["url"]})}
  end

  defp import_recipe_from_web do
    %Tool{
      name: "import_recipe_from_web",
      description:
        "Import a recipe from a url returned by find_recipe_web. Produces a proposal the user " <>
          "confirms before it enters the catalog. This ends your turn — do not call anything after it.",
      kind: :read,
      parameters: %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "a url from find_recipe_web's candidates"},
          slot_key: %{
            type: "string",
            description: "optional — the slot to assign the recipe to once the user confirms"
          },
          servings: %{type: "integer", minimum: 1}
        },
        required: ["url"]
      },
      run: fn args, ctx, plan ->
        case Tore.Recipes.scrape_attrs_from_url(scope(ctx), args["url"], household_locale(ctx)) do
          {:ok, attrs} ->
            {:proposal, web_import_proposal(attrs, args["url"]), pending_assignment(args), plan}

          {:error, _} = err ->
            err
        end
      end
    }
  end

  defp generate_recipe_variant do
    %Tool{
      name: "generate_recipe_variant",
      description:
        "Create a variant of an existing recipe — simpler, vegetarian, scaled to different " <>
          "servings, and so on. Produces a proposal the user confirms before it enters the " <>
          "catalog. This ends your turn — do not call anything after it.",
      kind: :read,
      parameters: %{
        type: "object",
        properties: %{
          recipe_ref: %{
            type: "string",
            description: "a ref returned by search_recipes, resolve_recipe, or resolve_slot"
          },
          instruction: %{
            type: "string",
            description: "how to change it, e.g. \"make it vegetarian\", \"simpler\", \"for 6\""
          },
          slot_key: %{
            type: "string",
            description: "optional — the slot to assign the variant to once the user confirms"
          },
          servings: %{type: "integer", minimum: 1}
        },
        required: ["recipe_ref", "instruction"]
      },
      run: fn args, ctx, plan ->
        # Read tools do not get the agent's recipe_ref exchange (that runs for
        # action tools only), so resolve the handle here.
        with {:ok, recipe_id} <- fetch_recipe_id(ctx, args["recipe_ref"]),
             recipe = Tore.Recipes.get!(scope(ctx), recipe_id),
             {:ok, proposal, usage} <-
               Tore.Recipes.Variant.build(recipe, args["instruction"], household_locale(ctx)) do
          SpendGuard.log_usage(:recipe_variant, usage)
          {:proposal, proposal, pending_assignment(args), plan}
        end
      end
    }
  end

  defp fetch_recipe_id(ctx, ref) do
    case Handles.fetch(Map.get(ctx, :handles, %{}), ref) do
      {:ok, %Handles.ResolvedRecipe{id: id}} ->
        {:ok, id}

      _ ->
        {:error,
         "unknown recipe_ref #{inspect(ref)} — call search_recipes or resolve_recipe first and use a ref from the result"}
    end
  end

  defp pending_assignment(%{"slot_key" => slot_key} = args) when is_binary(slot_key) do
    %{slot_key: slot_key, servings: args["servings"] || 4}
  end

  defp pending_assignment(_args), do: %{}

  defp web_import_proposal(attrs, url) do
    %Tore.Harness.Artifact.RecipeProposal{
      title: attrs[:title],
      description: attrs[:description],
      instructions: attrs[:instructions],
      base_servings: attrs[:base_servings],
      prep_time_minutes: attrs[:prep_time_minutes],
      cook_time_minutes: attrs[:cook_time_minutes],
      ingredients: Enum.map(attrs[:ingredients] || [], &web_import_ingredient/1),
      tags: attrs[:tags] || [],
      source: :web_import,
      source_url: url
    }
  end

  defp web_import_ingredient(ing) do
    %{
      name: ing[:name] || ing["name"],
      quantity: quantity_to_string(ing[:quantity] || ing["quantity"]),
      unit: ing[:unit] || ing["unit"]
    }
  end

  defp quantity_to_string(nil), do: nil
  defp quantity_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp quantity_to_string(n) when is_number(n), do: to_string(n)
  defp quantity_to_string(s) when is_binary(s), do: s

  defp guard_message, do: "web search is resting — try again shortly"

  defp scope(ctx), do: Tore.Scope.for_household(ctx.household_id)

  defp household_locale(ctx), do: Tore.Household.locale(scope(ctx))

  defp recipe_under_minutes?(%{prep_time_minutes: _, cook_time_minutes: _} = recipe, max) do
    total_minutes(recipe) <= max
  end

  defp recipe_under_minutes?(_, _), do: false

  defp summarise_recipe(r) do
    %{
      title: r.title,
      base_servings: r.base_servings,
      total_minutes: total_minutes(r)
    }
  end

  defp total_minutes(%{prep_time_minutes: p, cook_time_minutes: c}) do
    (p || 0) + (c || 0)
  end

  defp total_minutes(_), do: 0

  defp recipe_title(_ctx, nil), do: nil

  defp recipe_title(ctx, recipe_id) do
    Tore.Recipes.get!(scope(ctx), recipe_id).title
  rescue
    Ecto.NoResultsError -> nil
  end

  # Decide one command against the working plan; on success evolve it and return events.
  defp propose(%{slot_key: slot_key} = cmd, plan, result) do
    with :ok <- not_eating_out(plan, slot_key),
         {:ok, events} <- Decider.decide(cmd, plan) do
      next = Enum.reduce(events, plan, fn ev, acc -> Decider.evolve(acc, ev) end)
      {:ok, result, events, next}
    end
  end

  # A person said so, and the planner leaves that alone. Only a person can change it.
  defp not_eating_out(plan, slot_key) do
    if State.eating_out?(plan.slots[slot_key]), do: {:error, :slot_eating_out}, else: :ok
  end
end
