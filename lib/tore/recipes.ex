defmodule Tore.Recipes do
  import Ecto.Query
  alias Tore.{Repo, Scope}
  alias Tore.Recipes.{Recipe, Ingredient, RecipeIngredient, Tag}

  @http Application.compile_env(:tore, :http_client)
  @image_gen Application.compile_env(:tore, :image_gen_client)

  # An ingredient name will never contain this, so joined names split cleanly.
  @fp_sep "\x1f"

  @doc "The topic a household's recipe changes are broadcast on."
  @spec topic(Scope.t()) :: String.t()
  def topic(%Scope{household_id: id}), do: "recipes:household:#{id}"

  @doc """
  Creates a recipe and starts making its picture. Inside an outer transaction, such as a run's,
  pass `image: false` and call `start_image/2` once it commits, since the task can't see the
  recipe before then.
  """
  @spec create(Scope.t(), map(), keyword()) :: {:ok, Recipe.t()} | {:error, Ecto.Changeset.t()}
  def create(%Scope{} = scope, attrs, opts \\ []) do
    {tag_names, attrs} = Map.pop(attrs, :tags, [])
    {ingredients, attrs} = Map.pop(attrs, :ingredients, [])

    Repo.transaction(fn ->
      with {:ok, recipe} <- insert_recipe(scope, attrs),
           :ok <- insert_ingredients(scope, recipe, ingredients),
           {:ok, recipe} <- attach_tags(scope, recipe, tag_names) do
        recipe
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, recipe} ->
        if Keyword.get(opts, :image, true),
          do: maybe_generate_image(scope, recipe, Map.get(attrs, :image_url))

        {:ok, get!(scope, recipe.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update(Scope.t(), Recipe.t(), map()) :: {:ok, Recipe.t()} | {:error, Ecto.Changeset.t()}
  def update(
        %Scope{household_id: household_id} = scope,
        %Recipe{household_id: household_id} = recipe,
        attrs
      ) do
    {tag_names, attrs} = Map.pop(attrs, :tags, nil)
    {ingredients, attrs} = Map.pop(attrs, :ingredients, nil)

    Repo.transaction(fn ->
      with {:ok, updated} <- do_update(recipe, attrs),
           {:ok, updated} <- maybe_update_tags(scope, updated, tag_names),
           {:ok, updated} <- maybe_update_ingredients(scope, updated, ingredients) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, recipe} -> {:ok, get!(scope, recipe.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get!(Scope.t(), term()) :: Recipe.t()
  def get!(%Scope{} = scope, id) do
    Recipe
    |> Repo.get!(id, Scope.repo_opts(scope))
    |> Repo.preload([:tags, recipe_ingredients: :ingredient])
  end

  @doc "The recipe, or nil when there's none with that id in this household."
  @spec get(Scope.t(), term()) :: Recipe.t() | nil
  def get(%Scope{} = scope, id), do: Repo.get(Recipe, id, Scope.repo_opts(scope))

  @doc """
  Titles and ingredient names for every recipe, for duplicate detection.
  Keeps `RecipeProposalVerifier` pure — it compares against this, it does not
  query.
  """
  @spec catalog_fingerprints(Scope.t()) :: [%{title: String.t(), ingredient_names: [String.t()]}]
  def catalog_fingerprints(%Scope{} = scope) do
    from(r in Recipe,
      left_join: ri in RecipeIngredient,
      on: ri.recipe_id == r.id,
      left_join: i in Ingredient,
      on: i.id == ri.ingredient_id,
      group_by: r.id,
      select: %{
        title: r.title,
        ingredient_names: fragment("group_concat(?, ?)", i.name, ^@fp_sep)
      }
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> Enum.map(fn row -> %{row | ingredient_names: split_names(row.ingredient_names)} end)
  end

  defp split_names(nil), do: []
  defp split_names(joined), do: String.split(joined, @fp_sep)

  @spec list(Scope.t(), keyword()) :: [Recipe.t()]
  def list(%Scope{} = scope, opts \\ []) do
    Recipe
    |> filter_tags(opts[:tags])
    |> filter_type(opts[:type])
    |> filter_max_minutes(opts[:max_minutes])
    |> filter_weeknight(opts[:weeknight_friendly])
    |> apply_sort(opts[:sort])
    |> Repo.all(Scope.repo_opts(scope))
    |> Repo.preload([:tags])
  end

  @spec search(Scope.t(), String.t()) :: [Recipe.t()]
  def search(%Scope{} = scope, query) when is_binary(query) and byte_size(query) > 0 do
    term = "%#{query}%"

    from(r in Recipe,
      left_join: ri in RecipeIngredient,
      on: ri.recipe_id == r.id,
      left_join: i in Ingredient,
      on: i.id == ri.ingredient_id,
      where: like(r.title, ^term) or like(i.name, ^term),
      distinct: true
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> Repo.preload([:tags])
  end

  def search(%Scope{}, _query), do: []

  @spec delete(Scope.t(), Recipe.t()) :: {:ok, Recipe.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Scope{household_id: household_id}, %Recipe{household_id: household_id} = recipe),
    do: Repo.delete(recipe)

  @spec record_used(Scope.t(), integer()) :: :ok
  def record_used(%Scope{} = scope, recipe_id) do
    from(r in Recipe, where: r.id == ^recipe_id)
    |> Repo.update_all(
      [set: [last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)]],
      Scope.repo_opts(scope)
    )

    :ok
  end

  @spec scrape_from_url(Scope.t(), String.t()) :: {:ok, Recipe.t()} | {:error, term()}
  def scrape_from_url(%Scope{} = scope, url), do: scrape_and_create(scope, url)

  @doc """
  Fetch and parse a recipe URL **without** writing it to the catalog. Used by
  the planner's proposal path, where the user confirms before anything is
  saved. `scrape_from_url/2` is the eager version.
  """
  @spec scrape_attrs_from_url(Scope.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def scrape_attrs_from_url(%Scope{} = scope, url, locale \\ nil) do
    locale = locale || Tore.Household.locale(scope)

    with {:ok, html} <- @http.fetch(url),
         {:ok, attrs} <- parse_or_extract(scope, html, locale) do
      {:ok, Map.put(attrs, :source_url, url)}
    end
  end

  @spec extract_from_images(Scope.t(), [binary()]) :: {:ok, map()} | {:error, term()}
  def extract_from_images(%Scope{} = scope, binaries) do
    system = Tore.LLM.Prompts.parse_recipe_images(Tore.Household.locale(scope))
    blobs = Enum.map(binaries, &{:image, &1})

    with {:ok, data, _usage} <-
           Tore.LLM.vision(scope, blobs, system, "Extract the recipe from these images.",
             response_format: Tore.LLM.Prompts.recipe_json_schema(),
             feature: :extract_recipe
           ) do
      {:ok, recipe_attrs_from_raw(data)}
    end
  end

  @spec suggest_substitution(Scope.t(), String.t(), String.t()) ::
          {:ok, %{suggestion: String.t(), updated_steps: String.t() | nil}} | {:error, term()}
  def suggest_substitution(%Scope{} = scope, missing, recipe_context) do
    system = """
    You are a practical cooking assistant. The user is missing an ingredient mid-cook.
    Suggest a realistic substitution they can make right now with common kitchen items.
    If the substitution requires changing the steps, include brief updated instructions.
    Return JSON only: {"suggestion": "...", "updated_steps": "..." or null}
    Keep the suggestion to 1-2 sentences. Be direct and practical.
    """

    user = "Recipe: #{recipe_context}\nMissing ingredient: #{missing}"

    case Tore.LLM.text(scope, system, user, feature: :suggest_substitution) do
      {:ok, %{"suggestion" => suggestion} = data, _usage} ->
        {:ok, %{suggestion: suggestion, updated_steps: data["updated_steps"]}}

      {:ok, _, _} ->
        {:error, :invalid_response}

      {:error, _} = err ->
        err
    end
  end

  @spec cook_mode_steps(Scope.t(), map()) ::
          {:ok, %{do_first: [String.t()], while_cooking: [String.t()], finish: [String.t()]}}
          | {:error, term()}
  def cook_mode_steps(%Scope{} = scope, recipe) do
    system = """
    You are a cooking assistant. Compress recipe steps into a 3-phase action list.
    Phase 1 "do_first": things to start before anything else (pre-heat, prep, start slow things).
    Phase 2 "while_cooking": things to do while the main component cooks.
    Phase 3 "finish": final assembly and plating.
    Each phase is a list of short action phrases (5-10 words each). Max 4 items per phase.
    Return JSON only: {"do_first": [...], "while_cooking": [...], "finish": [...]}
    """

    title = recipe["title"] || recipe[:title] || "Unknown"
    instructions = recipe["instructions"] || recipe[:instructions] || "No instructions"
    user = "Recipe: #{title}\nSteps: #{instructions}"

    case Tore.LLM.text(scope, system, user, feature: :cook_mode) do
      {:ok, %{"do_first" => df, "while_cooking" => wc, "finish" => fin}, _usage} ->
        {:ok, %{do_first: df, while_cooking: wc, finish: fin}}

      {:ok, _, _} ->
        {:error, :invalid_response}

      {:error, _} = err ->
        err
    end
  end

  defp recipe_attrs_from_raw(data) do
    raw_steps = data["steps"] || []
    steps = Enum.sort_by(raw_steps, & &1["order"])

    instructions =
      steps
      |> Enum.chunk_by(& &1["phase"])
      |> Enum.map(fn phase_steps ->
        phase = hd(phase_steps)["phase"]
        lines = Enum.map(phase_steps, &"#{&1["order"]}. #{&1["action"]}") |> Enum.join("\n")
        "## #{phase}\n\n#{lines}"
      end)
      |> Enum.join("\n\n")

    %{
      title: data["title"],
      description: data["description"],
      prep_time_minutes: data["prep_time_minutes"],
      cook_time_minutes: data["cook_time_minutes"],
      base_servings: data["base_servings"],
      image_url: data["image_url"],
      ingredients: ingredients_from_raw(data["ingredients"] || []),
      tags: data["tags"] || [],
      steps: if(steps == [], do: nil, else: Jason.encode!(steps)),
      instructions: if(instructions == "", do: nil, else: instructions)
    }
    |> Map.reject(fn {_, v} -> is_nil(v) end)
  end

  defp ingredients_from_raw(list) do
    Enum.map(list, fn item ->
      %{
        name: item["item"] || item["name"],
        quantity: parse_decimal(item["quantity"]),
        unit: item["unit"]
      }
    end)
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(n) when is_number(n), do: Decimal.from_float(n * 1.0)
  defp parse_decimal(s) when is_binary(s), do: Decimal.new(s)

  # ── Private helpers ────────────────────────────────────────────────────────

  defp insert_recipe(scope, attrs) do
    %Recipe{household_id: scope.household_id}
    |> Recipe.changeset(attrs)
    |> Repo.insert()
  end

  defp insert_ingredients(_scope, _recipe, []), do: :ok

  defp insert_ingredients(scope, recipe, ingredients) do
    Enum.each(ingredients, fn ing_attrs ->
      name = Map.get(ing_attrs, :name) || Map.get(ing_attrs, "name")

      {:ok, ingredient} =
        %Ingredient{household_id: scope.household_id}
        |> Ingredient.changeset(%{name: name})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:household_id, :name])
        |> case do
          {:ok, %Ingredient{id: nil}} ->
            {:ok, Repo.get_by!(Ingredient, [name: name], Scope.repo_opts(scope))}

          result ->
            result
        end

      %RecipeIngredient{}
      |> RecipeIngredient.changeset(%{
        recipe_id: recipe.id,
        ingredient_id: ingredient.id,
        quantity: Map.get(ing_attrs, :quantity) || Map.get(ing_attrs, "quantity"),
        unit: Map.get(ing_attrs, :unit) || Map.get(ing_attrs, "unit"),
        notes: Map.get(ing_attrs, :notes) || Map.get(ing_attrs, "notes")
      })
      |> Repo.insert!()
    end)

    :ok
  end

  defp attach_tags(_scope, recipe, []), do: {:ok, recipe}

  defp attach_tags(scope, recipe, tag_names) do
    tags = Enum.map(tag_names, &upsert_tag(scope, &1))
    recipe = Repo.preload(recipe, :tags)

    recipe
    |> Recipe.tag_changeset(tags)
    |> Repo.update()
  end

  defp upsert_tag(scope, name) do
    %Tag{household_id: scope.household_id}
    |> Tag.changeset(%{name: name})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:household_id, :name])
    |> case do
      {:ok, %Tag{id: nil}} -> Repo.get_by!(Tag, [name: name], Scope.repo_opts(scope))
      {:ok, tag} -> tag
    end
  end

  defp do_update(recipe, attrs) do
    recipe
    |> Recipe.changeset(attrs)
    |> Repo.update()
  end

  defp maybe_update_tags(_scope, recipe, nil), do: {:ok, recipe}

  defp maybe_update_tags(scope, recipe, tag_names) do
    tags = Enum.map(tag_names, &upsert_tag(scope, &1))
    recipe = Repo.preload(recipe, :tags)

    recipe
    |> Recipe.tag_changeset(tags)
    |> Repo.update()
  end

  defp maybe_update_ingredients(_scope, recipe, nil), do: {:ok, recipe}

  defp maybe_update_ingredients(scope, recipe, ingredients) do
    Repo.delete_all(from ri in RecipeIngredient, where: ri.recipe_id == ^recipe.id)
    # insert_ingredients uses Repo.insert! — raises on failure, transaction rolls back
    insert_ingredients(scope, recipe, ingredients)
    {:ok, recipe}
  end

  @doc "Starts making the picture of a recipe created with `image: false`."
  @spec start_image(Scope.t(), integer()) :: :ok
  def start_image(%Scope{} = scope, recipe_id) do
    case get(scope, recipe_id) do
      nil -> :ok
      recipe -> maybe_generate_image(scope, recipe, nil)
    end

    :ok
  end

  defp maybe_generate_image(scope, recipe, image_url) do
    loaded = Repo.preload(recipe, recipe_ingredients: :ingredient)

    Task.start(fn ->
      generate_image(scope, loaded, image_url)
    end)
  end

  @spec scrape_and_create(Scope.t(), String.t(), String.t() | nil) ::
          {:ok, Recipe.t()} | {:error, term()}
  def scrape_and_create(%Scope{} = scope, url, locale \\ nil) do
    with {:ok, attrs} <- scrape_attrs_from_url(scope, url, locale) do
      create(scope, attrs)
    end
  end

  @spec generate_image(Scope.t(), Recipe.t(), String.t() | nil) :: :ok | {:error, term()}
  def generate_image(%Scope{} = scope, recipe, image_url) do
    storage = Tore.Storage.client()
    key = "households/#{scope.household_id}/recipes/#{recipe.id}/#{Ecto.UUID.generate()}.jpg"

    with {:ok, binary} <- fetch_or_generate(scope, recipe, image_url),
         {:ok, _url} <-
           storage.put_object(Tore.Storage.Buckets.recipes(), key, binary,
             content_type: "image/jpeg"
           ) do
      Repo.update_all(
        from(r in Recipe, where: r.id == ^recipe.id),
        [set: [image_path: key]],
        Scope.repo_opts(scope)
      )

      Phoenix.PubSub.broadcast(Tore.PubSub, topic(scope), {:recipe_image, recipe.id, key})

      :ok
    end
  end

  # Two paths in, one shape out. Whether the deterministic parser succeeded
  # or we had to fall back to LLM extraction, the result goes through the
  # LLM normaliser so every scraped recipe ends up translated to the
  # household's locale and reformatted to the Tore schema.
  defp parse_or_extract(scope, html, locale) do
    case Tore.Recipes.Parser.parse_html(html) do
      {:ok, scraped_attrs} -> normalise_recipe(scope, scraped_attrs, locale)
      {:error, :not_found} -> extract_from_html(scope, html, locale)
    end
  end

  defp extract_from_html(scope, html, locale) do
    with :ok <- check_html_parseable(scope, html) do
      {system, user} = Tore.LLM.Prompts.extract_recipe(html, locale)

      with {:ok, data, _usage} <-
             Tore.LLM.text(scope, system, user,
               response_format: Tore.LLM.Prompts.recipe_json_schema(),
               feature: :extract_recipe
             ) do
        {:ok, recipe_attrs_from_raw(data)}
      end
    end
  end

  defp normalise_recipe(scope, scraped_attrs, locale) do
    {system, user} = Tore.LLM.Prompts.normalise_recipe(scraped_attrs, locale)

    with {:ok, data, _usage} <-
           Tore.LLM.text(scope, system, user,
             response_format: Tore.LLM.Prompts.recipe_json_schema(),
             feature: :extract_recipe
           ) do
      {:ok, recipe_attrs_from_raw(data)}
    end
  end

  defp check_html_parseable(scope, html) do
    {system, user} = Tore.LLM.Prompts.check_recipe_html(html)
    check_model = Application.get_env(:tore, :openrouter_check_model, "openai/gpt-oss-120b:free")

    fallback =
      Application.get_env(:tore, :openrouter_check_model_fallback, "openai/gpt-oss-120b")

    result =
      case Tore.LLM.text(scope, system, user, model: check_model, feature: :check_recipe_html) do
        {:ok, _, _} = ok ->
          ok

        {:error, _} ->
          Tore.LLM.text(scope, system, user, model: fallback, feature: :check_recipe_html)
      end

    case result do
      {:ok, %{"parseable" => true}, _} -> :ok
      {:ok, %{"parseable" => false}, _} -> {:error, :not_a_recipe}
      {:ok, _, _} -> {:error, :not_a_recipe}
      {:error, _} = err -> err
    end
  end

  defp fetch_or_generate(_scope, _recipe, image_url)
       when is_binary(image_url) and image_url != "" do
    @http.fetch(image_url)
  end

  defp fetch_or_generate(scope, recipe, _image_url) do
    with {:ok, prompt} <- write_image_prompt(scope, recipe) do
      @image_gen.generate_food_image(prompt)
    end
  end

  defp write_image_prompt(scope, recipe) do
    locale = Tore.Household.locale(scope)
    payload = recipe_for_image_prompt(recipe)
    {system, user} = Tore.LLM.Prompts.write_image_prompt(payload, locale)

    case Tore.LLM.text(scope, system, user,
           response_format: Tore.LLM.Prompts.write_image_prompt_schema(),
           feature: :image_prompt
         ) do
      {:ok, %{"prompt" => prompt}, _usage} when is_binary(prompt) and prompt != "" ->
        {:ok, prompt}

      {:ok, _, _} ->
        {:error, :invalid_response}

      {:error, _} = err ->
        err
    end
  end

  # Shrink the recipe to what the image-prompt writer actually needs.
  defp recipe_for_image_prompt(recipe) do
    %{
      title: recipe.title,
      instructions: recipe.instructions,
      ingredients:
        recipe
        |> Map.get(:recipe_ingredients, [])
        |> List.wrap()
        |> Enum.map(fn ri ->
          name =
            case ri do
              %{ingredient: %{name: n}} -> n
              %{name: n} -> n
              _ -> nil
            end

          %{name: name}
        end)
        |> Enum.reject(&is_nil(&1.name))
    }
  end

  # ── Query filters ──────────────────────────────────────────────────────────

  defp filter_tags(query, nil), do: query
  defp filter_tags(query, []), do: query

  defp filter_tags(query, tag_names) do
    Enum.reduce(tag_names, query, fn name, q ->
      from r in q,
        join: rt in "recipe_tags",
        on: rt.recipe_id == r.id,
        join: t in Tag,
        on: t.id == rt.tag_id and t.name == ^name
    end)
  end

  defp filter_type(query, nil), do: query
  defp filter_type(query, :all), do: query
  defp filter_type(query, type), do: from(r in query, where: r.recipe_type == ^type)

  defp filter_max_minutes(query, nil), do: query
  defp filter_max_minutes(query, :any), do: query

  defp filter_max_minutes(query, max) when is_integer(max) do
    from r in query,
      where: coalesce(r.prep_time_minutes, 0) + coalesce(r.cook_time_minutes, 0) <= ^max
  end

  defp filter_weeknight(query, true) do
    query
    |> filter_max_minutes(45)
    |> filter_tags(["quick"])
  end

  defp filter_weeknight(query, _), do: query

  defp apply_sort(query, :last_used) do
    from r in query, order_by: [desc_nulls_last: r.last_used_at]
  end

  defp apply_sort(query, :alphabetical) do
    from r in query, order_by: [asc: r.title]
  end

  defp apply_sort(query, _) do
    from r in query, order_by: [desc: r.inserted_at]
  end
end
