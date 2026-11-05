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

  def plan_weekly(constraints) do
    dietary = dietary_guidance_instruction(constraints[:dietary_guidance])

    system = """
    You are a meal planner. Think like a prep cook.
    Goal: assign recipes to meal slots for the week.
    Principles:
    - Batch cook early in the week; cascade leftovers into later meals
    - Prefer ingredient reuse over variety
    - Respect pinned slots as hard constraints
    - Prefer pantry items and deals when available
    - Weeknight slots need recipes with total time ≤45 min#{dietary}
    Respond with a JSON object only. No prose.
    """

    user = render("plan_weekly.eex", constraints)
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

  def estimate_nutrition do
    system = File.read!(Path.join(@prompts_dir, "estimate_nutrition.eex"))
    {system, ""}
  end

  @recipe_schema """
  {
    "title": "string (required)",
    "description": "string or null",
    "prep_time_minutes": "integer or null",
    "cook_time_minutes": "integer or null",
    "base_servings": "integer or null",
    "image_url": "absolute URL string or null",
    "tags": ["string"],
    "ingredients": [
      { "item": "string", "quantity": "number or null", "unit": "string or null" }
    ],
    "steps": [
      {
        "phase": "string — cooking phase name in ALL CAPS (e.g. MISE EN PLACE, SAUCE, ASSEMBLY, COOKING, BAKING)",
        "order": "integer — global step number starting at 1",
        "action": "string — one clear, atomic cooking action",
        "ingredients": ["string — ingredient names used in this step"],
        "duration_minutes": "integer or null — only if this step has an explicit wait/cook time"
      }
    ]
  }
  """

  @recipe_json_schema %{
    type: "object",
    required: [
      "title",
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

  @recipe_rules """
  - title is required; steps and ingredients must always be arrays (empty if unknown)
  - CRITICAL: the steps array must be sorted in the exact order a cook performs them, start to finish
  - The "order" field is a single global counter: the first thing you do is order 1, the second is order 2, etc.
  - MISE EN PLACE (prep) always comes before any cooking phase — assign it the lowest order numbers
  - Cooking phases follow in the order they are actually executed, not the order they appear in the source
  - Example of correct ordering for a meatball recipe:
      order 1 phase "MISE EN PLACE" — chop onion
      order 2 phase "MISE EN PLACE" — mix meat and breadcrumbs
      order 3 phase "COOKING" — fry meatballs
      order 4 phase "SAUCE" — make sauce in same pan
      order 5 phase "SERVING" — plate with sides
  - each step is one atomic action — never combine multiple actions in one step
  - do not summarise or skip any steps from the source
  - reference ingredient names in each step's ingredients array exactly as they appear in the top-level ingredients list
  - ingredients: list every ingredient with "item" (name), "quantity" (number or null), "unit" (string or null, e.g. "g", "ml", "dl", "st", "msk", "tsk") — use null when not specified
  - tags: 1-3 lowercase tags (cuisine, main protein, or style — e.g. "chicken", "italian", "quick", "vegetarian")
  - Respond with a JSON object only. No prose.
  """

  def extract_recipe(html, locale \\ nil) do
    system = """
    You are a recipe extractor. Given raw HTML from a recipe webpage, extract the recipe.
    Return a JSON object matching this exact structure:
    #{@recipe_schema}
    Rules:
    #{@recipe_rules}
    #{translation_instruction(locale)}
    """

    {system, html}
  end

  @doc """
  Reformat and translate a recipe to the Tore schema. Use when a deterministic
  scraper (JSON-LD / microdata) already produced a structured recipe but it
  may be in another language or shaped differently from `recipe_json_schema/0`.
  """
  def normalise_recipe(attrs, locale \\ nil) do
    system = """
    You normalise an already-structured recipe into the Tore recipe schema.
    The input is a JSON-shaped recipe that may use different field names, units,
    or formatting from what Tore expects. Reformat it.

    Return a JSON object matching this exact structure:
    #{@recipe_schema}
    Rules:
    #{@recipe_rules}
    #{translation_instruction(locale)}
    """

    user = Jason.encode!(attrs)
    {system, user}
  end

  def parse_recipe_images(locale \\ nil) do
    """
    You are a recipe extractor. The user has photographed one or more pages of a recipe — ingredients may be on one image, instructions on another.
    Combine all images into a single complete recipe and return a JSON object matching this exact structure:
    #{@recipe_schema}
    Rules:
    #{@recipe_rules}
    #{translation_instruction(locale)}
    """
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

  @web_candidates_schema %{
    type: "object",
    properties: %{
      candidates: %{
        type: "array",
        items: %{
          type: "object",
          properties: %{
            title: %{type: "string"},
            url: %{type: "string"}
          },
          required: ["title", "url"],
          additionalProperties: false
        }
      }
    },
    required: ["candidates"],
    additionalProperties: false
  }

  def web_candidates_json_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "web_candidates", strict: true, schema: @web_candidates_schema}
    }
  end

  @doc """
  Discovery only. The model searches the web and hands back candidate recipe
  pages; it never writes the recipe itself — the chosen URL goes through the
  existing scraper, so the recipe text always comes from the real page.
  """
  def find_recipe_web(query, locale \\ nil) do
    system = """
    You find recipe pages on the web. Search for pages matching the user's request.

    Return a JSON object: {"candidates": [{"title": "...", "url": "..."}]}
    Rules:
    - return at most 5 candidates, best match first
    - each url must be a direct link to a single recipe page you actually found in the search results
    - never return a search-results page, a category listing, or a homepage
    - the title is the recipe's name as the page states it
    - prefer pages that show ingredients and steps as text
    - if nothing suitable was found, return {"candidates": []}
    - do not write out any recipe content — only titles and urls
    #{locale_preference_instruction(locale)}
    Respond with a JSON object only. No prose.
    """

    {system, query}
  end

  @doc """
  Generate a variant of an existing recipe (simpler, vegetarian, scaled to a
  different number of servings, …). The result is a complete recipe in the
  Tore schema, surfaced as a proposal — never auto-committed.
  """
  def generate_recipe_variant(source_recipe, instruction, locale \\ nil) do
    system = """
    You adapt an existing recipe. The user gives you a source recipe and an
    instruction describing how to change it. Produce the complete adapted recipe.

    Return a JSON object matching this exact structure:
    #{@recipe_schema}
    Rules:
    #{@recipe_rules}
    - the adapted recipe must stand alone: full ingredients and full steps, not a diff against the source
    - give it a title that says how it differs from the source
    - keep every change traceable to the instruction — change nothing the user did not ask for
    - when the instruction changes servings, scale every quantity accordingly and set base_servings to the requested number
    #{translation_instruction(locale)}
    """

    user =
      Jason.encode!(%{
        source_recipe: source_recipe,
        instruction: instruction
      })

    {system, user}
  end

  # Search results are better in the household's own language, but the prompt
  # itself stays English — locale is a parameter, never baked in.
  defp locale_preference_instruction(nil), do: ""

  defp locale_preference_instruction(locale) do
    case Map.get(@locale_names, locale) do
      nil ->
        ""

      language ->
        "- prefer recipe pages written in #{language}, but return good pages in any language if there are none"
    end
  end

  @receipt_json_schema %{
    type: "object",
    required: ["line_items"],
    additionalProperties: false,
    properties: %{
      line_items: %{
        type: "array",
        items: %{
          type: "object",
          required: ["product_name", "quantity", "unit_price", "total_price", "category"],
          additionalProperties: false,
          properties: %{
            product_name: %{type: "string"},
            quantity: %{type: ["number", "null"]},
            unit_price: %{type: ["number", "null"]},
            total_price: %{type: ["number", "null"]},
            category: %{
              type: "string",
              enum: [
                "dairy",
                "meat",
                "produce",
                "frozen",
                "dry_goods",
                "canned",
                "herbs_spices",
                "condiments",
                "other"
              ]
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

  def check_recipe_html(html) do
    system = """
    You are a recipe detector. Does the provided HTML contain a parseable recipe with ingredients and instructions?
    Respond ONLY with JSON: {"parseable": true} or {"parseable": false}.
    """

    user = String.slice(html, 0, 2000)
    {system, user}
  end

  @pantry_json_schema %{
    type: "object",
    required: ["items"],
    additionalProperties: false,
    properties: %{
      items: %{
        type: "array",
        items: %{
          type: "object",
          required: ["name", "quantity", "unit", "category", "expires_on"],
          additionalProperties: false,
          properties: %{
            name: %{type: "string"},
            quantity: %{type: ["number", "null"]},
            unit: %{type: ["string", "null"]},
            expires_on: %{
              type: ["string", "null"],
              description: "ISO 8601 yyyy-mm-dd date printed on the item; null if not readable."
            },
            category: %{
              type: "string",
              enum: [
                "dairy",
                "meat",
                "produce",
                "frozen",
                "dry_goods",
                "canned",
                "herbs_spices",
                "condiments",
                "other"
              ]
            }
          }
        }
      }
    }
  }

  def pantry_json_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "pantry_items", strict: true, schema: @pantry_json_schema}
    }
  end

  def parse_pantry_image do
    system = """
    You are a kitchen inventory assistant. Identify food and household items from photos.
    Respond with a JSON object only. No prose.
    """

    user = File.read!(Path.join(@prompts_dir, "parse_pantry_image.eex"))
    {system, user}
  end

  def parse_receipt do
    system = """
    You are a receipt parser. Extract line items from receipt images precisely.
    Respond with a JSON object only. No prose.
    """

    user = File.read!(Path.join(@prompts_dir, "parse_receipt.eex"))
    {system, user}
  end

  @receipt_pantry_json_schema %{
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
          required: ["name", "quantity", "unit", "category"],
          additionalProperties: false,
          properties: %{
            name: %{type: "string"},
            quantity: %{type: ["number", "null"]},
            unit: %{type: ["string", "null"]},
            # Constrain to the canonical English keys our schemas accept —
            # locale-aware names (e.g. "Mejeri & Ost") get rejected downstream
            # at the changeset, so force the model to pick from this set.
            category: %{
              type: "string",
              enum: [
                "dairy",
                "meat",
                "produce",
                "frozen",
                "dry_goods",
                "canned",
                "herbs_spices",
                "condiments",
                "other"
              ]
            }
          }
        }
      }
    }
  }

  def receipt_pantry_json_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "receipt_pantry", strict: true, schema: @receipt_pantry_json_schema}
    }
  end

  def parse_receipt_for_pantry(locale \\ nil) do
    system = """
    You are a receipt parser. Given a photo of a grocery receipt:
    1. Extract the store name (if visible).
    2. Extract the total amount paid (the final total).
    3. Extract the purchase date printed on the receipt, in ISO 8601
       (yyyy-mm-dd). If the receipt shows a locale-specific format
       (DD/MM/YYYY, MM-DD-YY, etc.), convert to ISO. If no date is
       visible, return null — do not guess.
    4. Extract each purchased grocery item with name, quantity, and unit.
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
              enum: [
                "dairy",
                "meat",
                "produce",
                "frozen",
                "dry_goods",
                "canned",
                "herbs_spices",
                "condiments",
                "other"
              ]
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
    - category: pick the best fit from dairy, meat, produce, frozen, dry_goods,
      canned, herbs_spices, condiments, other. Use "other" when nothing else
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

  @deals_json_schema %{
    type: "object",
    required: ["deals"],
    additionalProperties: false,
    properties: %{
      deals: %{
        type: "array",
        items: %{
          type: "object",
          required: [
            "chain",
            "store",
            "product_name",
            "brand",
            "size",
            "price",
            "price_unit",
            "offer_condition",
            "regular_price",
            "comparison_price",
            "valid_from",
            "valid_until"
          ],
          additionalProperties: false,
          properties: %{
            chain: %{type: "string"},
            store: %{type: "string"},
            product_name: %{type: "string"},
            brand: %{type: ["string", "null"]},
            size: %{type: ["string", "null"]},
            price: %{type: ["number", "null"]},
            price_unit: %{type: ["string", "null"]},
            offer_condition: %{type: ["string", "null"]},
            regular_price: %{type: ["string", "null"]},
            comparison_price: %{type: ["string", "null"]},
            valid_from: %{type: ["string", "null"]},
            valid_until: %{type: ["string", "null"]}
          }
        }
      }
    }
  }

  def deals_json_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "deals", strict: true, schema: @deals_json_schema}
    }
  end

  def parse_deals_pdf do
    system = """
    You are a grocery deals extractor. Given a PDF flyer or weekly deals catalog from a Swedish supermarket:
    Extract every product deal/offer into the structured format.
    - chain: lowercase chain identifier, one of: "ica", "coop", "lidl", "willys", "hemkop", "citygross", "other"
    - store: the full store name from the PDF (e.g. "ICA Maxi Flemingsberg", "Coop Forum Nacka")
    - product_name: the product name as printed
    - brand: brand name if separate from product name, else null
    - size: package size/weight (e.g. "500g", "1 kg", "6-pack"), null if not stated
    - price: sale price as a number (e.g. 29.90), null if not clear
    - price_unit: currency or unit for price (e.g. "kr", "kr/kg"), null if not stated
    - offer_condition: any condition text (e.g. "3 for 2", "2-pack", "Medlemspris"), null if none
    - regular_price: ordinary price as a number if shown crossed out, else null
    - comparison_price: comparison/unit price string as shown (e.g. "59.80 kr/kg"), null if not shown
    - valid_from / valid_until: ISO 8601 date strings (YYYY-MM-DD) if stated, else null
    Respond with a JSON object only. No prose.
    """

    {system, "Extract all deals from this PDF flyer."}
  end

  @grocery_section_schema %{
    type: "object",
    required: ["section"],
    additionalProperties: false,
    properties: %{
      section: %{
        type: "string",
        enum:
          ~w(produce meat fish dairy deli frozen bread dry_goods canned beverages herbs_spices condiments household other)
      }
    }
  }

  def grocery_section_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "grocery_section", strict: true, schema: @grocery_section_schema}
    }
  end

  @filter_pantry_schema %{
    type: "object",
    required: ["items"],
    additionalProperties: false,
    properties: %{
      items: %{
        type: "array",
        items: %{
          type: "object",
          required: ["name", "quantity", "unit", "section"],
          additionalProperties: false,
          properties: %{
            name: %{type: "string"},
            quantity: %{type: ["number", "null"]},
            unit: %{type: ["string", "null"]},
            section: %{
              type: "string",
              enum:
                ~w(produce meat fish dairy deli frozen bread dry_goods canned beverages herbs_spices condiments household other)
            }
          }
        }
      }
    }
  }

  def filter_pantry_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "filter_pantry", strict: true, schema: @filter_pantry_schema}
    }
  end

  def filter_pantry_items(ingredients, pantry) do
    ingredients_text =
      Enum.map_join(ingredients, "\n", fn i ->
        qty = if i.quantity, do: "#{i.quantity} #{i.unit} ", else: ""
        "- #{qty}#{i.name}"
      end)

    pantry_text =
      Enum.map_join(pantry, "\n", fn p ->
        qty = if p.quantity, do: "#{p.quantity} #{p.unit} ", else: ""
        "- #{qty}#{p.name}"
      end)

    system = """
    You are a smart shopping assistant. Given a list of required ingredients and a pantry inventory, return only the items that still need to be bought.
    Rules:
    - If an ingredient is fully covered by the pantry, omit it.
    - If partially covered, include it with the remaining quantity needed.
    - Match items by meaning, not exact string (e.g. "chicken fillet" matches "chicken").
    - Preserve original ingredient names and units in the output.
    - If an ingredient has no quantity, include it unless the pantry clearly has it.
    - Always omit water — it is assumed to be available.
    - For each item, assign a section: produce, meat, fish, dairy, deli, frozen, bread, dry_goods, canned, beverages, herbs_spices, condiments, household, or other.
    Respond with JSON only.
    """

    user = "Ingredients needed:\n#{ingredients_text}\n\nPantry:\n#{pantry_text}"
    {system, user}
  end

  def classify_grocery_item(name) do
    system = """
    You are a grocery store assistant. Classify a grocery item into exactly one store section.
    Sections: produce, meat, fish, dairy, deli, frozen, bread, dry_goods, canned, beverages, herbs_spices, condiments, household, other.
    Respond with JSON only.
    """

    {system, name}
  end

  def synthesise_insights(events_summary) do
    system = """
    You are a household cooking analyst. Given a summary of a family's meal planning events
    over the past 4 weeks, extract 3–7 durable observations about their patterns.

    Each insight must have:
    - kind: one of skip_pattern, cascade_success, time_preference, cuisine_fatigue, variety_win
    - body: one concise natural-language sentence (max 20 words), written as a present-tense observation
    - confidence: 0.0–1.0 based on how many events support it
    - evidence: array of integer event IDs that support this observation

    Return JSON only: {"insights": [{"kind": "...", "body": "...", "confidence": 0.0, "evidence": []}]}
    Omit any insight with confidence below 0.3.
    """

    user = "Planning events summary:\n#{events_summary}"
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

  # Strict JSON-schema so OpenRouter's structured-output mode enforces the
  # `{"prompt": "..."}` shape — no defensive parsing on the caller.
  @write_image_prompt_schema %{
    type: "object",
    required: ["prompt"],
    additionalProperties: false,
    properties: %{prompt: %{type: "string"}}
  }

  def write_image_prompt_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "image_prompt", strict: true, schema: @write_image_prompt_schema}
    }
  end

  @doc """
  Build a system + user prompt pair that asks a text LLM to write an image-gen
  prompt for `recipe`. The text LLM picks composition, lighting, mood, plating
  and cultural context based on the dish itself — so generated images vary in
  style across recipes rather than all looking like the same overhead-shot
  template.

  Use with `Tore.LLM.text/3` and `write_image_prompt_schema/0` as the
  `:response_format`. The reply will be `%{"prompt" => "<the image prompt>"}`.
  """
  def write_image_prompt(recipe, locale \\ nil) do
    system = """
    You write short, varied prompts for an image-generation model that
    illustrates cooked dishes.

    Goals for the prompt you write:
    - Describe the finished dish on a plate, in a bowl, or in whichever vessel
      best fits the cuisine.
    - Pick a composition (overhead, three-quarter, close-up, side-on) that
      flatters this specific dish — do not default to overhead for everything.
    - Pick a lighting mood (bright daylight, warm tungsten, golden hour, soft
      window light, moody low-key) that suits the dish. Vary it across calls.
    - Pick a surface and props (rustic wood, marble, linen, ceramic, enamel,
      glass) that suit the cuisine; avoid the same combo every time.
    - Mention typical garnishes, sauces, or side dishes that belong with the
      cuisine when relevant.
    - Keep the prompt 40-80 words. No markdown, no preamble — just the prompt
      itself as one paragraph of natural English (the image model speaks
      English).
    - Do not invent ingredients or details that contradict the recipe.
    #{locale_hint(locale)}
    """

    ingredients_line =
      case recipe[:ingredients] || recipe["ingredients"] do
        list when is_list(list) and list != [] ->
          names =
            list
            |> Enum.take(12)
            |> Enum.map(fn i -> Map.get(i, :name) || Map.get(i, "name") || "" end)
            |> Enum.reject(&(&1 == ""))
            |> Enum.join(", ")

          "Ingredients: #{names}"

        _ ->
          ""
      end

    instructions_excerpt =
      case recipe[:instructions] || recipe["instructions"] do
        s when is_binary(s) and s != "" -> "Method excerpt: #{String.slice(s, 0, 400)}"
        _ -> ""
      end

    user =
      [
        "Title: #{recipe[:title] || recipe["title"] || ""}",
        ingredients_line,
        instructions_excerpt
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    {system, user}
  end
end
