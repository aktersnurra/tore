defmodule Tore.Recipes do
  require Logger
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

  @doc "The household's recipes with these ids, ingredients loaded. Ids it doesn't have are left out."
  @spec get_many(Scope.t(), [integer()]) :: [Recipe.t()]
  def get_many(%Scope{} = scope, ids) do
    from(r in Recipe, where: r.id in ^Enum.uniq(ids), preload: [recipe_ingredients: :ingredient])
    |> Repo.all(Scope.repo_opts(scope))
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

  @doc """
  An ingredient amount for `servings` when the recipe is written for `base`: whole numbers from
  10 up, one decimal below, so 200 g for 4 is 300 g for 6 and 1 egg for 4 is 1.5 for 6.
  """
  @spec scale_quantity(Decimal.t() | nil, pos_integer() | nil, pos_integer()) :: Decimal.t() | nil
  def scale_quantity(nil, _base, _servings), do: nil
  def scale_quantity(quantity, nil, _servings), do: quantity
  def scale_quantity(quantity, base, base), do: quantity

  def scale_quantity(%Decimal{} = quantity, base, servings) do
    scaled = quantity |> Decimal.mult(servings) |> Decimal.div(base)
    places = if Decimal.compare(scaled, 10) == :lt, do: 1, else: 0
    rounded = Decimal.round(scaled, places)
    if Decimal.integer?(rounded), do: Decimal.new(Decimal.to_integer(rounded)), else: rounded
  end

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

  @doc """
  Stars a recipe, or takes its star away. Starred recipes are listed in the menu and first in
  Recipes, so the ones made often are two taps away.
  """
  @spec set_favorite(Scope.t(), integer(), boolean()) :: :ok
  def set_favorite(%Scope{} = scope, recipe_id, favorite?) when is_boolean(favorite?) do
    from(r in Recipe, where: r.id == ^recipe_id)
    |> Repo.update_all([set: [favorite: favorite?]], Scope.repo_opts(scope))

    Phoenix.PubSub.broadcast(Tore.PubSub, topic(scope), {:recipe_favorite, recipe_id, favorite?})
    :ok
  end

  @doc "The starred recipes, by name."
  @spec list_favorites(Scope.t()) :: [Recipe.t()]
  def list_favorites(%Scope{} = scope) do
    from(r in Recipe, where: r.favorite, order_by: [asc: r.title])
    |> Repo.all(Scope.repo_opts(scope))
  end

  @doc "The recipe was cooked `at` (now); `nil` puts back a recipe that never was."
  @spec record_used(Scope.t(), integer(), DateTime.t() | nil) :: :ok
  def record_used(%Scope{} = scope, recipe_id, at \\ DateTime.utc_now()) do
    at = at && DateTime.truncate(at, :second)

    from(r in Recipe, where: r.id == ^recipe_id)
    |> Repo.update_all([set: [last_used_at: at]], Scope.repo_opts(scope))

    :ok
  end

  @doc """
  Fetch and parse a recipe URL **without** writing it to the catalog. Used by
  the planner's proposal path, where the user confirms before anything is
  saved.
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
      {:ok, attrs_from_parsed(data)}
    end
  end

  @doc """
  The steps cook mode walks through, in order: maps with `"phase"`, `"order"`, `"action"`,
  `"ingredients"` (names) and `"duration_minutes"`.

  An imported recipe already has them. One that only has running text gets them written by the
  model the first time it's cooked, and they're kept on the recipe from then on.
  """
  @spec cook_steps(Scope.t(), Recipe.t()) :: {:ok, [map()]} | {:error, term()}
  def cook_steps(%Scope{} = scope, %Recipe{} = recipe) do
    case Recipe.decode_steps(recipe) do
      [] -> write_cook_steps(scope, recipe)
      steps -> {:ok, Enum.sort_by(steps, & &1["order"])}
    end
  end

  defp write_cook_steps(scope, recipe) do
    recipe = Repo.preload(recipe, recipe_ingredients: :ingredient)

    payload = %{
      title: recipe.title,
      instructions: recipe.instructions,
      ingredients:
        Enum.map(recipe.recipe_ingredients, fn ri ->
          %{item: ri.ingredient.name, quantity: ri.quantity, unit: ri.unit}
        end)
    }

    {system, user} = Tore.LLM.Prompts.cook_steps(payload, Tore.Household.locale(scope))

    case Tore.LLM.text(scope, system, user,
           response_format: Tore.LLM.Prompts.cook_steps_schema(),
           feature: :cook_mode
         ) do
      {:ok, %{"steps" => [_ | _] = steps}, _usage} ->
        steps = Enum.sort_by(steps, & &1["order"])

        Repo.update_all(
          from(r in Recipe, where: r.id == ^recipe.id),
          [set: [steps: Jason.encode!(steps)]],
          Scope.repo_opts(scope)
        )

        {:ok, steps}

      {:ok, _, _} ->
        {:error, :invalid_response}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Recipe attrs from a recipe in the shape `Tore.LLM.Prompts.recipe_json_schema/0` describes,
  whether Tore's model read it or someone's own Claude did over MCP.
  """
  @spec attrs_from_parsed(map()) :: map()
  def attrs_from_parsed(data) do
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
      recipe_type: recipe_type(data["recipe_type"]),
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

  defp recipe_type(type) when type in ~w(meal baking component assembly),
    do: String.to_existing_atom(type)

  defp recipe_type(_), do: nil

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

  @doc """
  Starts making the picture of a recipe created with `image: false`: fetched from `image_url`
  when there is one, otherwise generated in Tore's house style (`Tore.LLM.Prompts.food_photo/1`).
  Only a recipe saved over MCP passes `image_url`; everything else is generated, so the library
  looks like one cookbook.
  """
  @spec start_image(Scope.t(), integer(), String.t() | nil) :: :ok
  def start_image(%Scope{} = scope, recipe_id, image_url \\ nil) do
    case get(scope, recipe_id) do
      nil -> :ok
      recipe -> maybe_generate_image(scope, recipe, image_url)
    end

    :ok
  end

  # Off in tests (`config :tore, :recipe_images_in_background, false`), where the task would outlive
  # the test that owns its database connection and mocks. `generate_image/3` is tested directly.
  defp maybe_generate_image(scope, recipe, image_url) do
    if Application.get_env(:tore, :recipe_images_in_background, true) do
      loaded = Repo.preload(recipe, recipe_ingredients: :ingredient)

      Task.Supervisor.start_child(Tore.TaskSupervisor, fn ->
        with {:error, reason} <- generate_image(scope, loaded, image_url) do
          Logger.warning("no picture for recipe #{recipe.id}: #{inspect(reason)}")
        end
      end)
    end
  end

  @doc """
  Draws every recipe's picture again in the house style, one at a time, for every household.
  Each picture is a paid image call, so this is run by hand on the server
  (`bin/tore eval "Tore.Recipes.restyle_images()"`), never by the app. Returns how many were
  drawn and how many failed (a failed one keeps its old picture).
  """
  @spec restyle_images() :: %{drawn: non_neg_integer(), failed: non_neg_integer()}
  def restyle_images, do: draw_each(fn scope -> list(scope) end)

  @doc """
  Draws a picture for each recipe that has none, in every household: one whose picture failed
  when it was saved, or one from before pictures were drawn. `Tore.Scheduler` runs it at night,
  so no recipe stays without a photo for long. Each picture is a paid call, so it does nothing
  where `config :tore, :draw_missing_pictures, false` (dev and test).
  """
  @spec draw_missing_pictures() :: %{drawn: non_neg_integer(), failed: non_neg_integer()}
  def draw_missing_pictures do
    if Application.get_env(:tore, :draw_missing_pictures, true),
      do: draw_each(&without_picture/1),
      else: %{drawn: 0, failed: 0}
  end

  defp without_picture(scope),
    do: Repo.all(from(r in Recipe, where: is_nil(r.image_path)), Scope.repo_opts(scope))

  # One picture at a time, for the recipes `pick` gives in each household.
  defp draw_each(pick) do
    for id <- Tore.Household.list_ids(),
        scope = Scope.for_household(id),
        recipe <- scope |> pick.() |> Repo.preload(recipe_ingredients: :ingredient) do
      generate_image(scope, recipe, nil)
    end
    |> Enum.frequencies_by(&(&1 == :ok))
    |> then(&%{drawn: Map.get(&1, true, 0), failed: Map.get(&1, false, 0)})
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
        {:ok, attrs_from_parsed(data)}
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
      {:ok, attrs_from_parsed(data)}
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
    with {:ok, dish} <- write_image_prompt(scope, recipe) do
      @image_gen.generate_food_image(Tore.LLM.Prompts.food_photo(dish))
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
    from r in query, order_by: [desc: r.favorite, desc_nulls_last: r.last_used_at]
  end

  defp apply_sort(query, :alphabetical) do
    from r in query, order_by: [desc: r.favorite, asc: r.title]
  end

  # Starred recipes lead whichever order is chosen.
  defp apply_sort(query, _) do
    from r in query, order_by: [desc: r.favorite, desc: r.inserted_at]
  end
end
