defmodule Tore.Pantry.Lasts do
  @moduledoc """
  How long a pack of something lasts in the household, judged by Jev (`Tore.Jev`) once per
  ingredient that comes into the pantry: only for cooking (pasta, salmon, cream), or eaten
  between meals and gone in days (milk, bread), about a week (yoghurt, eggs) or weeks (butter,
  coffee). What's eaten between meals gets a half-life from it (`half_life_days/1`), so Tore
  believes it's being eaten without being told; what's only for cooking changes only when a
  dinner or the household says so. The household's own rhythm, once Basics has learned it, beats
  the guess (`Tore.Pantry.list_inventory/1`). In the same call Jev picks the picture its pantry row
  shows (`Tore.Pantry.Icons`).

  Spent from the household's AI budget, as pi is, and needs the same sponsor.
  """

  import Ecto.Query

  alias Tore.{Basics, Costs, Household, Jev, Pi, Repo, Scope}
  alias Tore.Pantry.{Icons, PantryItem}
  alias Tore.Recipes.Ingredient

  @batch 25

  @half_lives %{"cooking" => nil, "days" => 3, "week" => 7, "weeks" => 21}

  # What each answer means, as Jev is told.
  @criteria %{
    "cooking" =>
      "Bought for cooking dinners: it stays in the pantry until a dish uses it (pasta, rice, flour, meat, fish, cream, spices, sauces).",
    "days" =>
      "Eaten or drunk between meals and gone in a few days: breakfast, snacks, the kids' milk (milk, bread, fruit, juice).",
    "week" =>
      "Eaten between meals a little at a time, so a pack lasts about a week (yoghurt, eggs, cheese, cold cuts).",
    "weeks" =>
      "Used a little at a time, so a pack lasts several weeks (butter, coffee, tea, jam, cereal)."
  }

  @doc "The half-life Jev's answer gives, in days; nil for what's only for cooking."
  @spec half_life_days(String.t() | nil) :: pos_integer() | nil
  def half_life_days(lasts), do: Map.get(@half_lives, lasts)

  @doc """
  Asks Jev in the background about what's in the pantry that it hasn't been asked about, where
  Tore learns in the background (not in tests). A household without AI asks nothing.
  """
  @spec later(Scope.t()) :: :ok
  def later(%Scope{} = scope) do
    if Application.get_env(:tore, :learn, :background) == :background do
      Task.Supervisor.start_child(Tore.TaskSupervisor, fn -> sort(scope) end)
    end

    :ok
  end

  @doc """
  Asks Jev how each ingredient in the pantry is used and which picture it gets, whichever it
  hasn't been asked yet, and keeps its answers on the ingredients. Answers how many ingredients it
  kept something for. `opts` go to `Tore.Jev.decide/3`.
  """
  @spec sort(Scope.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sort(%Scope{} = scope, opts \\ []) do
    with :ok <- check(scope) do
      case unasked(scope) do
        [] -> {:ok, 0}
        ingredients -> scope |> ask(ingredients, opts, &questions/1) |> tell(scope)
      end
    end
  end

  @doc """
  Pictures for `ingredient_ids` that haven't one, in the background: what tonight needs and isn't
  kept, so Today's list to buy shows them as Hemma would.
  """
  @spec pictures_later(Scope.t(), [integer()]) :: :ok
  def pictures_later(%Scope{} = scope, ingredient_ids) do
    if Application.get_env(:tore, :learn, :background) == :background do
      Task.Supervisor.start_child(Tore.TaskSupervisor, fn -> pictures(scope, ingredient_ids) end)
    end

    :ok
  end

  @doc """
  Asks Jev only for the picture of each of `ingredient_ids` that hasn't one; how fast it goes is
  asked once it's kept (`sort/2`). Answers how many it kept a picture for.
  """
  @spec pictures(Scope.t(), [integer()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def pictures(%Scope{} = scope, ingredient_ids, opts \\ []) do
    with :ok <- check(scope) do
      from(i in Ingredient, where: i.id in ^ingredient_ids and is_nil(i.icon), order_by: i.name)
      |> Repo.all(Scope.repo_opts(scope))
      |> case do
        [] -> {:ok, 0}
        ingredients -> scope |> ask(ingredients, opts, &[picture_question(&1)]) |> tell(scope)
      end
    end
  end

  defp check(scope) do
    cond do
      Household.ai_sponsor(scope) == nil -> {:error, :ai_unavailable}
      Costs.llm_spend_this_month(scope) >= Pi.monthly_limit_usd() -> {:error, :budget_exceeded}
      true -> :ok
    end
  end

  defp unasked(scope) do
    from(i in Ingredient,
      join: p in PantryItem,
      on: p.ingredient_id == i.id,
      where: is_nil(i.lasts) or is_nil(i.icon),
      distinct: true,
      order_by: i.name
    )
    |> Repo.all(Scope.repo_opts(scope))
  end

  defp ask(scope, ingredients, opts, questions) do
    state = state(scope)

    ingredients
    |> Enum.chunk_every(@batch)
    |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, kept} ->
      case Jev.decide(state, batch |> Enum.flat_map(questions) |> Map.new(), opts) do
        {:ok, answers, cost} ->
          {:ok, _} = Costs.log_llm_usage(scope, %{feature: "pantry_lasts", cost_usd: cost})
          {:cont, {:ok, kept + keep(scope, batch, answers)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # Only what an ingredient lacks: one judged before a picture was asked for is asked for that.
  defp questions(%Ingredient{id: id, name: name} = ingredient) do
    [
      ingredient.lasts == nil &&
        {"lasts_#{id}",
         choice(
           "How does this household use #{name}, and how long does a pack of it last them?",
           @criteria
         )},
      ingredient.icon == nil && picture_question(ingredient)
    ]
    |> Enum.filter(& &1)
  end

  # The section, when Tore knows it, rules out the wild guesses at a word Jev doesn't know.
  defp picture_question(%Ingredient{id: id, name: name, category: section}) do
    kept = if section, do: " It's kept with #{String.replace(section, "_", " ")}.", else: ""
    {"icon_#{id}", choice("Which picture fits #{name} best?#{kept}", Icons.criteria())}
  end

  defp choice(instructions, criteria),
    do: %{"type" => "choice", "instructions" => instructions, "criteria" => criteria}

  # Hemma and Today show the half-lives and pictures just given.
  defp tell({:ok, kept} = sorted, scope) when kept > 0 do
    :ok = Tore.Pantry.changed(scope)
    sorted
  end

  defp tell(sorted, _scope), do: sorted

  defp keep(scope, batch, answers) do
    batch
    |> Enum.map(fn %Ingredient{id: id} ->
      [lasts(answers["lasts_#{id}"]), icon(answers["icon_#{id}"])]
      |> List.flatten()
      |> case do
        [] ->
          0

        # None when a learn job merged it away while Jev was answering.
        set ->
          {updated, _} =
            Repo.update_all(
              from(i in Ingredient, where: i.id == ^id),
              [set: set],
              Scope.repo_opts(scope)
            )

          updated
      end
    end)
    |> Enum.sum()
  end

  defp lasts(%{"choice" => lasts, "confidence" => confidence})
       when is_map_key(@half_lives, lasts) and is_number(confidence),
       do: [lasts: lasts, lasts_confidence: confidence / 1]

  defp lasts(_answer), do: []

  defp icon(%{"choice" => icon}), do: if(Icons.known?(icon), do: [icon: icon], else: [])
  defp icon(_answer), do: []

  # The household's language, as Jev is told it; none before the household has chosen one.
  defp language("sv"), do: "Its names are written in Swedish."
  defp language("en"), do: "Its names are written in English."
  defp language(nil), do: nil

  # What Tore knows of the household that bears on it, a line each.
  defp state(scope) do
    [
      "A household's pantry: how they use each thing they keep, and how fast it goes.",
      language(Household.locale(scope)),
      Household.Memory.snapshot(scope),
      case Enum.map(Basics.list(scope), & &1.name) do
        [] -> nil
        names -> "What they buy regularly beyond their dinners: #{Enum.join(names, ", ")}."
      end
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end
end
