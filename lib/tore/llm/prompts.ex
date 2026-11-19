defmodule Tore.LLM.Prompts do
  @prompts_dir Path.join(:code.priv_dir(:tore), "llm/prompts")

  def suggest_slot_recipe(context) do
    dietary = dietary_guidance_instruction(context[:dietary_guidance])

    system = """
    You are a meal planner suggesting one recipe for a single dinner slot.
    Goal: pick the best fit from the candidate recipes given week context.
    Principles:
    - Reuse ingredients from neighboring meals
    - Prefer pantry items and current deals
    - Avoid recipes already cooked this week
    - Match the day's available time and energy#{dietary}
    You MUST pick a recipe_id from the provided candidate list.
    Respond ONLY with JSON: {"recipe_id": <int>, "reasoning": "<one short sentence>"}.
    """

    user = render("suggest_slot_recipe.eex", context)
    {system, user}
  end

  @recipe_json_schema %{
    type: "object",
    required: [
      "title",
      "recipe_type",
      "description",
      "prep_time_minutes",
      "cook_time_minutes",
      "base_servings",
      "image_url",
      "tags",
      "ingredients",
      "steps"
    ],
    additionalProperties: false,
    properties: %{
      title: %{type: "string"},
      recipe_type: %{type: "string", enum: ["meal", "baking", "component", "assembly"]},
      description: %{type: ["string", "null"]},
      prep_time_minutes: %{type: ["integer", "null"]},
      cook_time_minutes: %{type: ["integer", "null"]},
      base_servings: %{type: ["integer", "null"]},
      image_url: %{type: ["string", "null"]},
      tags: %{type: "array", items: %{type: "string"}},
      ingredients: %{
        type: "array",
        items: %{
          type: "object",
          required: ["item", "quantity", "unit"],
          additionalProperties: false,
          properties: %{
            item: %{type: "string"},
            quantity: %{type: ["number", "null"]},
            unit: %{type: ["string", "null"]}
          }
        }
      },
      steps: %{
        type: "array",
        items: %{
          type: "object",
          required: ["phase", "order", "action", "ingredients", "duration_minutes"],
          additionalProperties: false,
          properties: %{
            phase: %{type: "string"},
            order: %{type: "integer"},
            action: %{type: "string"},
            ingredients: %{type: "array", items: %{type: "string"}},
            duration_minutes: %{type: ["integer", "null"]}
          }
        }
      }
    }
  }

  def recipe_json_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "recipe", strict: true, schema: @recipe_json_schema}
    }
  end

  @receipt_json_schema %{
    type: "object",
    required: ["total", "store_name", "purchase_date", "items"],
    additionalProperties: false,
    properties: %{
      total: %{type: ["number", "null"]},
      store_name: %{type: ["string", "null"]},
      purchase_date: %{
        type: ["string", "null"],
        description: "ISO 8601 yyyy-mm-dd date printed on the receipt; null if not visible."
      },
      items: %{
        type: "array",
        items: %{
          type: "object",
          required: ["name", "quantity", "unit", "total_price", "category"],
          additionalProperties: false,
          properties: %{
            name: %{type: "string"},
            quantity: %{type: ["number", "null"]},
            unit: %{type: ["string", "null"]},
            total_price: %{type: ["number", "null"]},
            # Constrain to the canonical English keys our schemas accept —
            # locale-aware names (e.g. "Mejeri & Ost") get rejected downstream
            # at the changeset, so force the model to pick from this set.
            category: %{
              type: "string",
              enum: Tore.Recipes.Ingredient.sections()
            }
          }
        }
      }
    }
  }

  def receipt_json_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "receipt", strict: true, schema: @receipt_json_schema}
    }
  end

  defp dietary_guidance_instruction(nil), do: ""
  defp dietary_guidance_instruction(""), do: ""

  defp dietary_guidance_instruction(guidance),
    do: "\n- Dietary guidance: #{String.trim(guidance)}"

  defp render(template, assigns) do
    path = Path.join(@prompts_dir, template)
    EEx.eval_file(path, assigns: Map.to_list(assigns))
  end

  @doc """
  What to use instead of what's missing, before someone starts cooking: what they say they
  have first, then the pantry, never anything else. One answer per missing ingredient.
  """
  def swaps(payload, locale) do
    language = Map.get(@locale_names, locale, "English")

    system = """
    Someone is about to cook a recipe and some of its ingredients aren't at home. For each one
    in "missing", say what to use instead.
    - Pick from "they_have" (what they just told you they have) first, then from "pantry".
      Never suggest anything that is in neither: then "use" is null.
    - If what they have doesn't work for that ingredient in this dish, "use" is null and the
      note says why.
    - If the dish is fine without it, "use" is null and the note says to leave it out.
    - "note" is one short sentence: the amount, and any change to how it's used. null when it's
      the same amount, used the same way.
    - "for" is the missing ingredient exactly as given. One entry per missing ingredient.
    - Write "use" and "note" in #{language}.
    Respond with a JSON object only. No prose.
    """

    {system, Jason.encode!(payload)}
  end

  def swaps_schema do
    %{
      type: "json_schema",
      json_schema: %{
        name: "swaps",
        strict: true,
        schema: %{
          type: "object",
          required: ["swaps"],
          additionalProperties: false,
          properties: %{
            swaps: %{
              type: "array",
              items: %{
                type: "object",
                required: ["for", "use", "note"],
                additionalProperties: false,
                properties: %{
                  for: %{type: "string"},
                  use: %{type: ["string", "null"]},
                  note: %{type: ["string", "null"]}
                }
              }
            }
          }
        }
      }
    }
  end
end
