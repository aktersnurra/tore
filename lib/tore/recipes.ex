defmodule Tore.Recipes do
  import Ecto.Query

  require Logger
  alias Tore.{Repo, Scope}
  alias Tore.Recipes.{Recipe, Ingredient, RecipeIngredient, RecipePart, Tag}

  @image_gen Application.compile_env(:tore, :image_gen_client)
  @http Application.compile_env(:tore, :http_client)

  # An ingredient name will never contain this, so joined names split cleanly.
  @fp_sep "\x1f"

  # Every recipe picture is taken the same way, so the library reads as one cookbook in Tore's
  # cast-iron palette. pi only describes the dish; this sets the light, surface and frame.
  @house_style """
  Editorial cookbook photograph, vertical 3:4 frame, shot from about 45 degrees. The dish sits \
  on a dark, matte charcoal stoneware or seasoned cast-iron surface. Soft, warm light from a \
  single window on one side, deep warm shadows, gentle amber highlights. Muted natural colours; \
  the food is the brightest thing in the frame. Plain matte ceramic or the dish's own pan, at \
  most one quiet prop such as linen or a wooden spoon. Shallow depth of field, natural and \
  appetising, not glossy. No text, no hands, no people, no logos.\
  """

  @snapshot_fields ~w(title description instructions steps recipe_type base_servings prep_time_minutes cook_time_minutes source_url image_path)a

  @doc "The topic a household's recipe changes are broadcast on."
  @spec topic(Scope.t()) :: String.t()
  def topic(%Scope{household_id: id}), do: "recipes:household:#{id}"

  @doc "Creates a recipe. Its picture and missing cook steps come from pi (`finish/3`)."
  @spec create(Scope.t(), map()) :: {:ok, Recipe.t()} | {:error, Ecto.Changeset.t()}
  def create(%Scope{} = scope, attrs) do
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
        clear_orders_with(scope, updated.id)
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

  @doc "The recipe with its ingredients, and a meal's parts with theirs (`with_parts/2`)."
  @spec get!(Scope.t(), term()) :: Recipe.t()
  def get!(%Scope{} = scope, id) do
    recipe =
      Recipe
      |> Repo.get!(id, Scope.repo_opts(scope))
      |> Repo.preload([:tags, recipe_ingredients: :ingredient])

    scope |> with_parts([recipe]) |> hd()
  end

  @doc "The household's recipes with these ids, ingredients loaded. Ids it doesn't have are left out."
  @spec get_many(Scope.t(), [integer()]) :: [Recipe.t()]
  def get_many(%Scope{} = scope, ids) do
    from(r in Recipe, where: r.id in ^Enum.uniq(ids), preload: [recipe_ingredients: :ingredient])
    |> Repo.all(Scope.repo_opts(scope))
    |> then(&with_parts(scope, &1))
  end

  @doc """
  Puts a meal together from recipes the household has (`part_ids`, in order): a dinner whose
  ingredients are its parts', and which follows them when they change. A part can't have parts
  of its own. The caller has pi write its cooking order and draw its picture (`finish/3`); when a
  part changes, the order is cleared and written again the next time the meal is cooked.
  """
  @spec put_together(
          Scope.t(),
          %{title: String.t(), servings: pos_integer(), part_ids: [integer()]}
        ) ::
          {:ok, Recipe.t()}
          | {:error, :too_few_parts | :unknown_parts | :nested | Ecto.Changeset.t()}
  def put_together(%Scope{} = scope, %{title: title, servings: servings, part_ids: ids}) do
    ids = Enum.uniq(ids)
    parts = get_many(scope, ids)

    cond do
      length(ids) < 2 -> {:error, :too_few_parts}
      length(parts) < length(ids) -> {:error, :unknown_parts}
      Enum.any?(parts, &(&1.parts != [])) -> {:error, :nested}
      true -> insert_meal(scope, title, servings, ids)
    end
  end

  defp insert_meal(scope, title, servings, ids) do
    Repo.transaction(fn ->
      with {:ok, meal} <-
             insert_recipe(scope, %{title: title, base_servings: servings, recipe_type: :meal}) do
        for {part_id, position} <- Enum.with_index(ids, 1) do
          Repo.insert!(%RecipePart{recipe_id: meal.id, part_id: part_id, position: position})
        end

        meal
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, meal} ->
        {:ok, get!(scope, meal.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The meals a recipe is a part of, by title."
  @spec meals_with(Scope.t(), integer()) :: [Recipe.t()]
  def meals_with(%Scope{} = scope, part_id) do
    from(r in Recipe,
      join: p in RecipePart,
      on: p.recipe_id == r.id,
      where: p.part_id == ^part_id,
      order_by: r.title
    )
    |> Repo.all(Scope.repo_opts(scope))
  end

  # A meal's parts, and their ingredients as the meal's: each part's scaled from its servings to
  # the meal's, then the same ingredient in the same unit added up. Recipes without parts are
  # left as they are. `recipes` have their ingredients loaded.
  defp with_parts(scope, recipes) do
    links =
      Repo.all(
        from(p in RecipePart,
          where: p.recipe_id in ^Enum.map(recipes, & &1.id),
          order_by: p.position
        )
      )

    if links == [] do
      recipes
    else
      parts =
        from(r in Recipe,
          where: r.id in ^Enum.uniq(Enum.map(links, & &1.part_id)),
          preload: [recipe_ingredients: :ingredient]
        )
        |> Repo.all(Scope.repo_opts(scope))
        |> Map.new(&{&1.id, &1})

      by_meal = Enum.group_by(links, & &1.recipe_id, & &1.part_id)

      Enum.map(recipes, fn recipe ->
        case by_meal[recipe.id] do
          nil -> recipe
          part_ids -> put_parts(recipe, for(id <- part_ids, part = parts[id], do: part))
        end
      end)
    end
  end

  defp put_parts(meal, parts) do
    from_parts =
      Enum.flat_map(parts, fn part ->
        for ri <- part.recipe_ingredients do
          %{ri | quantity: scale_part(ri.quantity, part.base_servings, meal.base_servings)}
        end
      end)

    %{meal | parts: parts, recipe_ingredients: add_up(meal.recipe_ingredients ++ from_parts)}
  end

  defp scale_part(quantity, _base, nil), do: quantity
  defp scale_part(quantity, base, servings), do: scale_quantity(quantity, base, servings)

  # The same ingredient in the same unit is one row, in the order it first appears. A row with no
  # amount ("some dragon") adds nothing to one that has one.
  defp add_up(rows) do
    rows
    |> Enum.group_by(&{&1.ingredient_id, &1.unit && String.downcase(&1.unit)})
    |> Map.values()
    |> Enum.sort_by(fn [first | _] -> Enum.find_index(rows, &(&1 == first)) end)
    |> Enum.map(fn [first | _] = same ->
      amounts = for %{quantity: %Decimal{} = q} <- same, do: q
      %{first | quantity: if(amounts == [], do: nil, else: Enum.reduce(amounts, &Decimal.add/2))}
    end)
  end

  # A part changed, so the meals that have it need their cooking order written again.
  defp clear_orders_with(scope, part_id) do
    meal_ids = Repo.all(from(p in RecipePart, where: p.part_id == ^part_id, select: p.recipe_id))

    if meal_ids != [] do
      Repo.update_all(
        from(r in Recipe, where: r.id in ^meal_ids),
        [set: [steps: nil]],
        Scope.repo_opts(scope)
      )
    end
  end

  @doc "The recipe, or nil when there's none with that id in this household."
  @spec get(Scope.t(), term()) :: Recipe.t() | nil
  def get(%Scope{} = scope, id), do: Repo.get(Recipe, id, Scope.repo_opts(scope))

  @doc """
  Titles and ingredient names for every recipe but `except_id`, for duplicate detection.
  Keeps `RecipeProposalVerifier` pure — it compares against this, it does not
  query.
  """
  @spec catalog_fingerprints(Scope.t(), integer() | nil) :: [
          %{title: String.t(), ingredient_names: [String.t()]}
        ]
  def catalog_fingerprints(%Scope{} = scope, except_id \\ nil) do
    except = if except_id, do: dynamic([r], r.id != ^except_id), else: true

    from(r in Recipe,
      where: ^except,
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
  What cooking `recipe` (its ingredients loaded) for `servings` takes from the pantry, for
  `Tore.Pantry.use_up/2`: each ingredient with its amount scaled.
  """
  @spec uses(Recipe.t(), pos_integer()) :: [Tore.Pantry.use()]
  def uses(%Recipe{} = recipe, servings) do
    for ri <- recipe.recipe_ingredients,
        do: %{
          name: ri.ingredient.name,
          quantity: scale_quantity(ri.quantity, recipe.base_servings, servings),
          unit: ri.unit
        }
  end

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
    |> filter_without_parts(opts[:without_parts])
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
  The steps cook mode walks through, in order: maps with `"phase"`, `"order"`, `"action"`,
  `"ingredients"` (names) and `"duration_minutes"`. Empty for a recipe pi hasn't written steps
  for yet (`finish/3`).
  """
  @spec cook_steps(Recipe.t()) :: [map()]
  def cook_steps(%Recipe{} = recipe),
    do: recipe |> Recipe.decode_steps() |> Enum.sort_by(& &1["order"])

  @doc """
  Has pi finish a recipe in the background (`harness/tasks/finish_recipe.md`): write its cook
  steps when it has none, and draw its picture when it has none. `details` says what else, such
  as "Its instructions were changed by hand." The changes arrive as `{:recipe_changed, id}`.
  """
  @spec finish(Scope.t(), integer(), String.t() | nil) :: :ok
  def finish(%Scope{} = scope, recipe_id, details \\ nil) when is_integer(recipe_id) do
    Tore.Agent.start(scope, "finish_recipe", Enum.join(["Recipe #{recipe_id}.", details], " "))
  end

  @doc """
  Has pi draw every recipe's picture again, one at a time, for every household. Each picture is a
  paid image call, so this is run by hand on the server
  (`bin/tore eval "Tore.Recipes.restyle_images()"`), never by the app.
  """
  @spec restyle_images() :: :ok
  def restyle_images do
    for id <- Tore.Household.list_ids(), scope = Scope.for_household(id), recipe <- list(scope) do
      Tore.Agent.run(scope, "finish_recipe", nil, "Recipe #{recipe.id}. Draw its picture again.")
    end

    :ok
  end

  @doc """
  Draws a picture of `dish` in Tore's one house style and stores it for the recipe, without
  setting it: `update_picture` in a run does that, so undo puts the old one back. `dish`
  describes only the finished food; the light, surface and frame are fixed here, so the library
  reads as one cookbook. What it cost goes into the household's AI spend as `recipe_picture`.
  """
  @spec draw_picture(Scope.t(), integer(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def draw_picture(%Scope{} = scope, recipe_id, dish) when is_binary(dish) do
    key = "households/#{scope.household_id}/recipes/#{recipe_id}/#{Ecto.UUID.generate()}.jpg"

    with {:ok, %{image: binary, cost_usd: cost}} <-
           @image_gen.generate_food_image(String.trim(dish) <> "\n\n" <> @house_style),
         {:ok, _usage} <-
           Tore.Costs.log_llm_usage(scope, %{feature: "recipe_picture", cost_usd: cost}),
         {:ok, _url} <-
           Tore.Storage.client().put_object(Tore.Storage.Buckets.recipes(), key, binary,
             content_type: "image/jpeg"
           ),
         do: {:ok, key}
  end

  @doc """
  A just-saved recipe's picture and steps: the photo on its page when pi passed one (`image_url`),
  fetched for free, then `finish/3` for whatever is still missing, so pi draws a picture only
  when there's no photo to use. In the background, like `finish/3`.
  """
  @spec finish_saved(Scope.t(), integer(), String.t() | nil) :: :ok
  def finish_saved(%Scope{} = scope, recipe_id, image_url) when is_binary(image_url) do
    work = fn ->
      with {:error, reason} <- put_page_picture(scope, recipe_id, image_url) do
        Logger.info("recipe #{recipe_id}: page photo not used (#{inspect(reason)})")
      end

      finish(scope, recipe_id)
    end

    if Application.get_env(:tore, :agent_in_background, true) do
      {:ok, _pid} = Task.Supervisor.start_child(Tore.TaskSupervisor, work)
      :ok
    else
      work.()
    end
  end

  def finish_saved(%Scope{} = scope, recipe_id, _image_url), do: finish(scope, recipe_id)

  defp put_page_picture(scope, recipe_id, url) do
    key = "households/#{scope.household_id}/recipes/#{recipe_id}/#{Ecto.UUID.generate()}.jpg"

    with {:ok, binary} <- @http.fetch(url),
         {:ok, _url} <-
           Tore.Storage.client().put_object(Tore.Storage.Buckets.recipes(), key, binary,
             content_type: "image/jpeg"
           ) do
      Repo.update_all(
        from(r in Recipe, where: r.id == ^recipe_id),
        [set: [image_path: key]],
        Scope.repo_opts(scope)
      )

      Phoenix.PubSub.broadcast(Tore.PubSub, topic(scope), {:recipe_changed, recipe_id})
      :ok
    end
  end

  @doc """
  The recipe as it is now, as JSON, for undo to put back with `restore/3`: its fields, picture,
  tags and ingredients.
  """
  @spec snapshot(Recipe.t()) :: map()
  def snapshot(%Recipe{} = recipe) do
    recipe = Repo.preload(recipe, [:tags, recipe_ingredients: :ingredient])

    recipe
    |> Map.take(@snapshot_fields)
    |> Map.update!(:recipe_type, &(&1 && Atom.to_string(&1)))
    |> Map.put(:tags, Enum.map(recipe.tags, & &1.name))
    |> Map.put(
      :ingredients,
      for ri <- recipe.recipe_ingredients do
        %{
          "name" => ri.ingredient.name,
          "quantity" => ri.quantity && Decimal.to_string(ri.quantity),
          "unit" => ri.unit,
          "notes" => ri.notes
        }
      end
    )
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc "The keys `snapshot/1` gives."
  @spec snapshot_keys() :: [String.t()]
  def snapshot_keys, do: Enum.map(@snapshot_fields, &Atom.to_string/1) ++ ~w(tags ingredients)

  @doc "Puts a recipe back as `snapshot/1` took it. A recipe since deleted stays deleted."
  @spec restore(Scope.t(), integer(), map()) :: :ok
  def restore(%Scope{} = scope, recipe_id, snapshot) do
    case get(scope, recipe_id) do
      nil ->
        :ok

      recipe ->
        attrs =
          Map.new(@snapshot_fields, &{&1, snapshot[Atom.to_string(&1)]})
          |> Map.put(:tags, snapshot["tags"])
          |> Map.put(
            :ingredients,
            for i <- snapshot["ingredients"] do
              %{
                name: i["name"],
                quantity: i["quantity"] && Decimal.new(i["quantity"]),
                unit: i["unit"],
                notes: i["notes"]
              }
            end
          )

        {:ok, _} = __MODULE__.update(scope, recipe, attrs)
        :ok
    end
  end

  @doc """
  Recipe attrs from a recipe in the shape `save_recipe` takes (`Tore.Mcp.Tools.SaveRecipe.schema/0`).
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
        unit: item["unit"],
        notes: item["notes"]
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
  Has pi draw a picture for each recipe that has none, in every household: one whose picture
  failed when it was saved, or one from before pictures were drawn. `Tore.Scheduler` runs it at
  night, so no recipe stays without a photo for long. Each picture is a paid call, so it does
  nothing where `config :tore, :draw_missing_pictures, false` (dev and test).
  """
  @spec draw_missing_pictures() :: :ok
  def draw_missing_pictures do
    if Application.get_env(:tore, :draw_missing_pictures, true) do
      for id <- Tore.Household.list_ids(),
          scope = Scope.for_household(id),
          recipe <-
            Repo.all(from(r in Recipe, where: is_nil(r.image_path)), Scope.repo_opts(scope)) do
        Tore.Agent.run(scope, "finish_recipe", nil, "Recipe #{recipe.id}.")
      end
    end

    :ok
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

  # What can be a part: a recipe that isn't itself put together from parts.
  defp filter_without_parts(query, true),
    do: from(r in query, where: r.id not in subquery(from(p in RecipePart, select: p.recipe_id)))

  defp filter_without_parts(query, _), do: query

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
