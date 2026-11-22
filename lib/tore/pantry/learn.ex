defmodule Tore.Pantry.Learn do
  @moduledoc """
  What a new name means, worked out by Jev (`Tore.Jev`) afterwards. A tick or an add never waits
  for it: a name Tore has never seen gets its ingredient as written at once, and Jev then says
  whether it's an ingredient the household has (*Mellanmjölk* is *Mjölk*: merged into it, the
  name kept as an alias), and its section and how long it keeps. Jev picks the same ingredient
  only among the household's names one inside the other, and a merge needs it to be sure, since
  recipes and pantry rows move with it. An ingredient that has a section is learned already, so
  it's never asked about again. A household without AI skips this, and the name stays as written.

  pi says the same through `learn_ingredients` (`learn/2`) when someone puts a name right in the
  chat, and matches product names on offers and receipt lines in a `learn` job (`ask/2`,
  `Tore.Prices.Products`).
  """

  import Ecto.Query

  require Logger

  alias Tore.{Agent, Costs, Jev, Pi, Repo, Scope}
  alias Tore.Pantry.{IngredientAlias, Match, PantryItem}
  alias Tore.Recipes.{Ingredient, RecipeIngredient}

  @type item :: %{
          name: String.t(),
          same_as: String.t() | nil,
          section: String.t(),
          shelf_life_days: pos_integer() | nil
        }

  @batch 25

  # Jev merges a new name into one the household has only this sure. Jev was 0.68 sure that
  # lättmjölk is mjölk (2026-11-21), so 0.9 merged almost nothing.
  @sure 0.65

  # Where each kind of thing is found in a shop, as Jev is told: in English, then in Swedish.
  @sections %{
    "produce" => "Fruit and vegetables; frukt och grönt",
    "meat" => "Meat and poultry, mince; kött, fågel, färs, kyckling",
    "fish" => "Fish and seafood; fisk och skaldjur",
    "dairy" =>
      "Milk, cream, yoghurt, cheese, butter, eggs; mejeri: mjölk, grädde, fil, yoghurt, ost, smör, ägg",
    "deli" => "Cold cuts, sausages, ready meals, hummus; chark och färdigmat, pålägg, korv",
    "frozen" => "Frozen food; frysvaror, fryst",
    "bread" => "Bread and baked goods; bröd, knäckebröd, kakor",
    "dry_goods" =>
      "Pasta, rice, flour, sugar, cereal, nuts, baking; torrvaror: pasta, ris, mjöl, socker, flingor, nötter",
    "canned" => "Tins and jars; konserver: krossade tomater, bönor, kokosmjölk",
    "beverages" => "Drinks; drycker: kaffe, te, juice, läsk, öl, vin",
    "herbs_spices" => "Herbs and spices; kryddor och örter",
    "condiments" => "Sauces, oils, vinegar, dressings; såser, olja, vinäger, senap, ketchup",
    "household" => "Not food: cleaning, paper, toiletries; hushåll: diskmedel, toapapper, tvål",
    "other" => "Anything else; övrigt"
  }

  # How long a thing keeps once bought, in days, and what each means as Jev is told.
  @keeps %{"days" => 4, "week" => 7, "weeks" => 21, "months" => 90, "year" => 365}

  @keeps_criteria %{
    "days" =>
      "Goes off within a few days: fresh fish, mince, berries, salad leaves; färsk fisk, färs, bär, sallad",
    "week" =>
      "Keeps about a week: milk, cream, bread, most vegetables; mjölk, grädde, bröd, grönsaker",
    "weeks" =>
      "Keeps a few weeks: cheese, butter, eggs, root vegetables; ost, smör, ägg, rotfrukter",
    "months" => "Keeps for months: jam, frozen food, bottled sauces; sylt, frysvaror, flasksåser",
    "year" => "Keeps a year or more: dry goods, tins, spices; torrvaror, konserver, kryddor"
  }

  @doc """
  Learns `names` after the caller has moved on, then runs `then`, if given. Off in tests
  (`config :tore, :learn`).
  """
  @spec later(Scope.t(), [String.t()], (-> any()) | nil) :: :ok
  def later(%Scope{} = scope, names, then \\ nil) do
    if Application.get_env(:tore, :learn, :background) == :background do
      Task.Supervisor.start_child(Tore.TaskSupervisor, fn ->
        names(scope, names)
        if then, do: then.()
      end)
    end

    :ok
  end

  @doc """
  Asks Jev about every name in `names` not learned yet, and waits for it. A name Tore has never
  seen gets its ingredient first, as written. One Jev didn't answer for stays unlearned and is
  asked again next time. `opts` go to `Tore.Jev.decide/3`.
  """
  @spec names(Scope.t(), [String.t()], keyword()) :: :ok
  def names(%Scope{} = scope, names, opts \\ []) do
    with :ok <- Jev.check(scope),
         [_ | _] = learning <- unlearned(scope, names) do
      learning
      |> Enum.chunk_every(@batch)
      |> Enum.each(&decide(scope, &1, opts))
    end

    :ok
  end

  defp decide(scope, batch, opts) do
    ids = Enum.map(batch, & &1.id)
    others = Repo.all(from(i in Ingredient, where: i.id not in ^ids), Scope.repo_opts(scope))
    shortlists = Map.new(batch, &{&1.id, lookalikes(&1, others)})
    questions = batch |> Enum.flat_map(&questions(&1, shortlists[&1.id])) |> Map.new()

    with {:ok, answers, cost} <- Jev.decide(state(scope), questions, opts) do
      {:ok, _} = Costs.log_llm_usage(scope, %{feature: "learn", cost_usd: cost})
      Enum.each(batch, &keep(scope, &1, shortlists[&1.id], answers))
    end
  end

  # The household's ingredients a new name could be a kind of, or the other way round: one name
  # inside the other ("mjölk" in "mellanmjölk"). Jev picks only among these.
  defp lookalikes(%Ingredient{key: key}, others) do
    others
    |> Enum.filter(fn %Ingredient{key: other} ->
      String.length(other) >= 3 and (String.contains?(key, other) or String.contains?(other, key))
    end)
    |> Enum.take(8)
  end

  defp questions(%Ingredient{id: id, name: name}, lookalikes) do
    [
      {"section_#{id}", choice("Where in a shop is #{name} found?", @sections)},
      {"keeps_#{id}", choice("How long does #{name} keep once bought?", @keeps_criteria)}
      | same_question(id, name, lookalikes)
    ]
  end

  defp same_question(_id, _name, []), do: []

  defp same_question(id, name, lookalikes) do
    criteria =
      Map.new(lookalikes, &{&1.name, "The same as #{&1.name}: a kind or a brand of it."})
      |> Map.put("own", "A thing of its own, none of these.")

    [
      {"same_#{id}",
       choice(
         "Is #{name} the same thing as one the household has, bought and cooked as one? " <>
           "Mellanmjölk is Mjölk; kokosmjölk is not.",
         criteria
       )}
    ]
  end

  defp choice(instructions, criteria),
    do: %{"type" => "choice", "instructions" => instructions, "criteria" => criteria}

  defp keep(scope, %Ingredient{id: id, name: name}, lookalikes, answers) do
    with %{"choice" => section} <- answers["section_#{id}"] do
      learn(scope, %{
        name: name,
        same_as: same_as(answers["same_#{id}"], lookalikes),
        section: section,
        shelf_life_days: with(%{"choice" => keeps} <- answers["keeps_#{id}"], do: @keeps[keeps])
      })
    end
  end

  defp same_as(%{"choice" => same, "confidence" => confidence}, lookalikes)
       when is_number(confidence) and confidence >= @sure,
       do: Enum.find_value(lookalikes, &(&1.name == same and &1.name))

  # Shown, so the line for sure can be tuned against what Jev really answers.
  defp same_as(%{"choice" => same, "confidence" => confidence}, lookalikes) do
    if Enum.any?(lookalikes, &(&1.name == same)),
      do: Logger.info("Learn: not sure enough to merge into #{same} (#{confidence})")

    nil
  end

  defp same_as(_answer, _lookalikes), do: nil

  # What Tore knows that bears on it, a line each.
  defp state(scope) do
    Enum.reject(
      [
        "A household's shopping: what each new name they wrote is, where it's found in a shop, and how long it keeps.",
        Jev.names_language(scope)
      ],
      &is_nil/1
    )
  end

  @doc "Runs a `learn` job with `details` (the products), and waits for it."
  @spec ask(Scope.t(), String.t()) :: :ok
  def ask(%Scope{} = scope, details) do
    if Pi.check(scope) == :ok, do: Agent.run(scope, "learn", nil, details)
    :ok
  end

  @doc """
  What pi said a name is (`learn_ingredients`): the ingredient it is the same as, which it is
  merged into, or its own section and shelf life. A section Tore doesn't have is kept as other.
  """
  @spec learn(Scope.t(), item()) :: :merged | :filled | {:error, :unknown_name | :unknown_same_as}
  def learn(%Scope{} = scope, %{name: name} = item) do
    with {:ok, ingredient} <- found(scope, name, :unknown_name),
         learned when learned in [:merged, :filled] <- learn(scope, ingredient, item) do
      # Hemma moves the row where it now belongs.
      :ok = Tore.Pantry.changed(scope)
      learned
    end
  end

  defp learn(scope, ingredient, item) do
    case item.same_as && found(scope, item.same_as, :unknown_same_as) do
      nil ->
        fill(ingredient, item)
        :filled

      {:ok, %Ingredient{id: id}} when id == ingredient.id ->
        fill(ingredient, item)
        :filled

      {:ok, into} ->
        {:ok, :ok} = merge(scope, ingredient, into)
        if into.category == nil, do: fill(into, item)
        :merged

      {:error, _} = error ->
        error
    end
  end

  defp found(scope, name, error) do
    case Match.ingredient(scope, {:name, name}) do
      {:ok, ingredient} -> {:ok, ingredient}
      :unknown -> {:error, error}
    end
  end

  @doc """
  The ingredient a product name means, when a barcode is first scanned: one the name already
  matches, or a new one called after the product, which a `learn` job then tidies (merged into
  *Mjölk* for *Arla Mellanmjölk 1,5 %*, its barcode with it).
  """
  @spec product(Scope.t(), String.t()) :: Ingredient.t()
  def product(%Scope{} = scope, product_name) do
    case Match.ingredient(scope, {:name, product_name}) do
      {:ok, ingredient} ->
        ingredient

      :unknown ->
        [ingredient] = new_ingredient(scope, product_name)
        later(scope, [product_name])
        ingredient
    end
  end

  defp unlearned(scope, names) do
    names
    |> Enum.uniq_by(&Ingredient.to_key/1)
    |> Enum.flat_map(fn name ->
      case Match.ingredient(scope, {:name, name}) do
        {:ok, %Ingredient{category: nil} = ingredient} -> [ingredient]
        {:ok, _learned} -> []
        :unknown -> new_ingredient(scope, name)
      end
    end)
  end

  defp new_ingredient(scope, name) do
    case Ingredient.to_key(name) do
      "" ->
        []

      _ ->
        [
          %Ingredient{household_id: scope.household_id}
          |> Ingredient.changeset(%{name: String.trim(name)})
          |> Repo.insert!()
        ]
    end
  end

  # `change/2`, not the changeset, which would re-derive the key.
  defp fill(ingredient, item) do
    section = if item.section in Ingredient.sections(), do: item.section, else: "other"

    ingredient
    |> Ecto.Changeset.change(
      category: section,
      shelf_life_days: ingredient.shelf_life_days || item.shelf_life_days
    )
    |> Repo.update!()
  end

  # Everything that pointed at `from` points at `into`, and `from`'s name becomes an alias. The
  # pantry holds one row per ingredient, so a row `into` already has wins.
  defp merge(scope, %Ingredient{} = from, %Ingredient{} = into) do
    opts = Scope.repo_opts(scope)

    Repo.transaction(fn ->
      Repo.update_all(
        from(r in RecipeIngredient, where: r.ingredient_id == ^from.id),
        [set: [ingredient_id: into.id]],
        opts
      )

      if Repo.get_by(PantryItem, [ingredient_id: into.id], opts) do
        Repo.delete_all(from(p in PantryItem, where: p.ingredient_id == ^from.id), opts)
      else
        Repo.update_all(
          from(p in PantryItem, where: p.ingredient_id == ^from.id),
          [set: [ingredient_id: into.id, name: String.downcase(into.name)]],
          opts
        )
      end

      Repo.update_all(
        from(a in IngredientAlias, where: a.ingredient_id == ^from.id),
        [set: [ingredient_id: into.id]],
        opts
      )

      Repo.delete!(from)
      :ok = Match.learn_alias(scope, {:name, from.name}, into.id)
    end)
  end
end
