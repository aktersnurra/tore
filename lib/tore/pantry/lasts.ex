defmodule Tore.Pantry.Lasts do
  @moduledoc """
  How long a pack of something lasts in the household, judged by Jev (`Tore.Jev`) once per
  ingredient that comes into the pantry: only for cooking (pasta, salmon, cream), or eaten
  between meals and gone in days (milk, bread), about a week (yoghurt, eggs) or weeks (butter,
  coffee). What's eaten between meals gets a half-life from it (`half_life_days/1`), so Tore
  believes it's being eaten without being told; what's only for cooking changes only when a
  dinner or the household says so. The household's own rhythm, once Basics has learned it, beats
  the guess (`Tore.Pantry.list_inventory/1`).

  Spent from the household's AI budget, as pi is, and needs the same sponsor.
  """

  import Ecto.Query

  alias Tore.{Basics, Costs, Household, Jev, Pi, Repo, Scope}
  alias Tore.Pantry.PantryItem
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
  Asks Jev how each ingredient in the pantry is used, for those not asked about yet, and keeps its
  answers on the ingredients. Answers how many it kept. `opts` go to `Tore.Jev.decide/3`.
  """
  @spec sort(Scope.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sort(%Scope{} = scope, opts \\ []) do
    with :ok <- check(scope) do
      case unasked(scope) do
        [] -> {:ok, 0}
        ingredients -> ask(scope, ingredients, opts)
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
      where: is_nil(i.lasts),
      distinct: true,
      order_by: i.name
    )
    |> Repo.all(Scope.repo_opts(scope))
  end

  defp ask(scope, ingredients, opts) do
    state = state(scope)

    ingredients
    |> Enum.chunk_every(@batch)
    |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, kept} ->
      questions =
        Map.new(
          batch,
          &{key(&1),
           %{"type" => "choice", "instructions" => question(&1), "criteria" => @criteria}}
        )

      case Jev.decide(state, questions, opts) do
        {:ok, answers, cost} ->
          {:ok, _} = Costs.log_llm_usage(scope, %{feature: "pantry_lasts", cost_usd: cost})
          {:cont, {:ok, kept + keep(scope, batch, answers)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp keep(scope, batch, answers) do
    kept =
      for ingredient <- batch,
          %{"choice" => lasts, "confidence" => confidence} <- [answers[key(ingredient)]],
          Map.has_key?(@half_lives, lasts) and is_number(confidence) do
        from(i in Ingredient, where: i.id == ^ingredient.id)
        |> Repo.update_all(
          [set: [lasts: lasts, lasts_confidence: confidence / 1]],
          Scope.repo_opts(scope)
        )
      end

    length(kept)
  end

  defp key(%Ingredient{id: id}), do: "ingredient_#{id}"

  defp question(%Ingredient{name: name}),
    do: "How does this household use #{name}, and how long does a pack of it last them?"

  # What Tore knows of the household that bears on it, a line each.
  defp state(scope) do
    [
      "A household's pantry: how they use each thing they keep, and how fast it goes.",
      Household.Memory.snapshot(scope),
      case Enum.map(Basics.list(scope), & &1.name) do
        [] -> nil
        names -> "What they buy regularly beyond their dinners: #{Enum.join(names, ", ")}."
      end
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end
end
