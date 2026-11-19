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

  def prep_guide(plan, locale \\ nil) do
    system = """
    You are a sous chef. Generate a Sunday prep session guide for the week's meals.
    Think in cascades: prep components that transform into different dishes across the week.
    Respond with a JSON object only. No prose.
    CRITICAL: JSON keys (prep_session, proteins, bases, sauces, vegetables, timeline, cascade_map, storage_notes, daily_assembly, task, detail, duration_min, step) must remain in English exactly as shown. Only translate string values.#{translation_instruction(locale)}
    """

    user = render("prep_guide.eex", plan)
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

  @locale_names %{
    "sv" => "Swedish",
    "en" => "English",
    "de" => "German",
    "fr" => "French",
    "es" => "Spanish",
    "no" => "Norwegian",
    "da" => "Danish",
    "fi" => "Finnish"
  }

  defp translation_instruction(nil), do: ""

  defp translation_instruction(locale) do
    case Map.get(@locale_names, locale) do
      nil ->
        ""

      language ->
        "- Translate ALL text field VALUES (title, description, tags, step phases, step actions, ingredient names) into #{language}. Keep units as-is (g, ml, msk, tsk, etc.). NEVER translate JSON keys — only values."
    end
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

  def parse_receipt(locale \\ nil) do
    system = """
    You are a receipt parser. Given a photo of a grocery receipt:
    1. Extract the store name (if visible).
    2. Extract the total amount paid (the final total).
    3. Extract the purchase date printed on the receipt, in ISO 8601
       (yyyy-mm-dd). If the receipt shows a locale-specific format
       (DD/MM/YYYY, MM-DD-YY, etc.), convert to ISO. If no date is
       visible, return null — do not guess.
    4. Extract each purchased grocery item with name, quantity, unit, and
       total_price: what the row cost in total, after any discount printed
       directly under it. Null if the row shows no amount.
       - Omit administrative line items: shopping bags, deposit/pant, returns,
         loyalty discounts, fees. These are not products.
       - Include food AND kitchen/cooking consumables a household would track
         (e.g. baking parchment, foil, plastic wrap, cling film, baking cups,
         paper towels used for cooking). These categorise as "other".
       - Keep product names exactly as written on the receipt — do not translate.
       - Use the unit conventions natural to the receipt's language.
       - Column alignment matters: each quantity belongs to the row it sits
         on. Before emitting, sanity-check that you have not pulled a number
         from a neighbouring row. If two adjacent items share the same name,
         emit two separate rows with their own quantities — do not merge.

    Quantity policy:
    - Weight-priced row (decimal quantity with a per-kg/per-lb price): emit the
      weight as-is, do not multiply.
      (e.g. a row showing "0.835" against a per-kg price → quantity 0.835, unit "kg".)
    - Pack-encoded name (a suffix like "10P", "4P", "6X33CL" indicating pack
      size): when the customer bought K such packs and the pack size is
      unambiguous, report TOTAL UNITS (K × pack_size) as a count, not packs.
      (e.g. an item name ending in "10P" bought ×2 → quantity 20, unit is the
      local count unit such as "pcs"/"st"/"Stk". NOT quantity 2.)
      If pack size is ambiguous, fall back to K packages.
    - Plain integer quantity with no weight/pack hint: simple count.
      (e.g. quantity "3" of an item with no pack code → quantity 3, count unit.)
    - If a row has a quantity, ALWAYS emit a unit — decimals with per-weight
      pricing → "kg"/"lb"; integer counts → the locale's count unit ("st"/"pcs"/etc).
      Only emit a null unit when quantity is also null (item unidentifiable).
    #{locale_hint(locale)}
    Respond with a JSON object only. No prose.
    """

    user = "Extract the store name, total, and grocery items from this receipt."
    {system, user}
  end

  defp locale_hint(nil), do: ""

  defp locale_hint(locale) do
    case Map.get(@locale_names, locale) do
      nil -> ""
      name -> "\nThis receipt is from a #{name}-speaking region."
    end
  end

  @estimate_prices_schema %{
    type: "object",
    required: ["items"],
    additionalProperties: false,
    properties: %{
      items: %{
        type: "array",
        items: %{
          type: "object",
          required: ["name", "price", "unit"],
          additionalProperties: false,
          properties: %{
            name: %{type: "string"},
            price: %{type: ["number", "null"]},
            unit: %{type: "string", enum: ["kg", "l", "st"]}
          }
        }
      }
    }
  }

  def estimate_prices_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "estimate_prices", strict: true, schema: @estimate_prices_schema}
    }
  end

  @doc "A guess at each ingredient's typical supermarket price, per kg, litre or item."
  def estimate_prices(ingredients, locale) do
    region =
      case Map.get(@locale_names, locale) do
        nil -> "the household's country"
        language -> "a country where #{language} is spoken"
      end

    system = """
    You estimate typical everyday supermarket prices for grocery ingredients in #{region}, in the
    local currency, at regular (not offer) prices.

    For each ingredient emit:
    - name: the input, unchanged.
    - unit: how it is usually priced: "kg" for things sold by weight, "l" for liquids, "st" for
      things bought as single items or packs.
    - price: the typical price for one kg, one litre or one item. Null only if it isn't food.

    Respond with a JSON object only. No prose.
    """

    user = "Estimate prices for:\n" <> Enum.map_join(ingredients, "\n", &"  - #{&1.name}")
    {system, user}
  end

  @canonicalise_pantry_schema %{
    type: "object",
    required: ["items"],
    additionalProperties: false,
    properties: %{
      items: %{
        type: "array",
        items: %{
          type: "object",
          required: [
            "raw_name",
            "catalogue_name",
            "category",
            "default_unit",
            "matched_key",
            "shelf_life_days"
          ],
          additionalProperties: false,
          properties: %{
            raw_name: %{type: "string"},
            catalogue_name: %{type: "string"},
            category: %{
              type: "string",
              enum: Tore.Recipes.Ingredient.sections()
            },
            default_unit: %{type: ["string", "null"]},
            matched_key: %{type: ["string", "null"]},
            shelf_life_days: %{type: ["integer", "null"]}
          }
        }
      }
    }
  }

  def canonicalise_pantry_schema do
    %{
      type: "json_schema",
      json_schema: %{
        name: "canonicalise_pantry",
        strict: true,
        schema: @canonicalise_pantry_schema
      }
    }
  end

  def canonicalise_pantry_items(items, locale, catalogue) do
    locale_name = Map.get(@locale_names, locale)

    catalogue_lines =
      catalogue
      |> Enum.map(fn %{key: k, name: n} -> "  #{k}  (#{n})" end)
      |> Enum.join("\n")

    items_lines =
      items
      |> Enum.map(fn it -> "  - #{Map.get(it, :raw_name) || Map.get(it, "raw_name")}" end)
      |> Enum.join("\n")

    locale_phrase =
      if locale_name,
        do:
          "The items are in #{locale_name}. Use that knowledge to expand " <>
            "common abbreviations, restore missing diacritics, and repair OCR " <>
            "misspellings of well-known grocery terms confidently.",
        else: ""

    system = """
    You normalise raw grocery item names (often abbreviated/all-caps OCR
    output) into a canonical ingredient catalogue.

    For each raw item, emit:
    - raw_name: the input, unchanged.
    - catalogue_name: the ingredient-level name a cookbook or recipe would
      use, NOT the product variant. Strip brand, pack size, size grade, fat
      percentage, packaging, supplier or organic-certification qualifiers.
      Use the locale's natural orthography (diacritics, capitalisation, word
      boundaries) — the OCR is unreliable, you are not. Be confident.
    - category: pick the best fit from produce, meat, fish, dairy, deli, frozen, bread, dry_goods,
      canned, beverages, herbs_spices, condiments, household, other. Use "other" when nothing else
      fits — never leave it empty.
    - default_unit: the most natural single-purchase unit for this ingredient
      in the locale's conventions.
    - matched_key: if this catalogue_name maps to an existing catalogue key,
      emit that key. Otherwise null (a new ingredient will be created).
      Match at the INGREDIENT level, not the product variant — different
      brands, pack sizes, fat percentages, or grades all map to one key.
    - shelf_life_days: roughly how many days this ingredient keeps at home from
      when it's bought, unopened and stored normally. Your best estimate is
      fine. Use null only when the item isn't food.

    #{locale_phrase}

    Existing catalogue keys (key — display name):
    #{catalogue_lines}

    Respond with a JSON object only. No prose.
    """

    user = "Canonicalise these items:\n#{items_lines}"
    {system, user}
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
