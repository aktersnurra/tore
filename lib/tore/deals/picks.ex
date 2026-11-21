defmodule Tore.Deals.Picks do
  @moduledoc """
  How each current offer fits a household, sorted by Jev (`Tore.Jev`) from what Tore knows of
  them: diet and allergies, their memory, this week's meals, what they usually buy, what they
  bought lately and their recipes. Each offer is something they buy (`:usual`), something they
  might want (`:maybe`) or not for them (`:no`). With little known Jev guesses from the little
  there is, and it gets better as receipts come in. Each offer is asked about once per household,
  as a `choice` question, after the morning's fetch and when a store is added. It is spent from
  the household's AI budget, as pi is, and needs the same sponsor.
  """

  import Ecto.Query

  alias Tore.{Basics, Costs, Deals, Household, Jev, Recipes, Repo, Scope, Shop, Streams}
  alias Tore.Costs.{LineItem, Receipt}
  alias Tore.Deals.{Deal, Pick}

  # Questions in one call to Jev.
  @batch 25
  @lately_days 8 * 7
  @max_lines 40

  @type kind :: :usual | :maybe | :no

  @kinds %{"usual" => :usual, "maybe" => :maybe, "no" => :no}

  # What each answer means, as Jev is told.
  @criteria %{
    "usual" =>
      "Something they buy regularly, or the same kind of thing: it's in what they buy or bought lately.",
    "maybe" =>
      "Not something they usually buy, but it fits their diet, their cooking and their tastes, so they might well want it this week.",
    "no" =>
      "Not for them: it breaks their diet or allergies, it's for a pet, baby or need they don't have, or nothing about them suggests they'd buy it."
  }

  @doc "Jev's answer for each offer it has been asked about, by deal id: its kind and how sure."
  @spec all(Scope.t()) :: %{integer() => {kind(), float()}}
  def all(%Scope{} = scope) do
    from(p in Pick, select: {p.deal_id, p.kind, p.confidence})
    |> Repo.all(Scope.repo_opts(scope))
    |> Map.new(fn {id, kind, confidence} -> {id, {Map.fetch!(@kinds, kind), confidence}} end)
  end

  @doc """
  Asks Jev about the current offers it hasn't been asked about for the household, and keeps its
  answers. Answers how many it kept. `opts` go to `Tore.Jev.decide/3`.
  """
  @spec sort(Scope.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sort(%Scope{} = scope, opts \\ []) do
    with :ok <- Jev.check(scope) do
      asked = all(scope)

      case Enum.reject(Deals.list_current(scope), &Map.has_key?(asked, &1.id)) do
        [] -> {:ok, 0}
        deals -> ask(scope, deals, opts)
      end
    end
  end

  defp ask(scope, deals, opts) do
    state = state(scope)

    deals
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
          {:ok, _} = Costs.log_llm_usage(scope, %{feature: "deal_picks", cost_usd: cost})
          {:cont, {:ok, kept + keep(scope, batch, answers)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp keep(scope, batch, answers) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for deal <- batch,
          %{"choice" => kind, "confidence" => confidence} <- [answers[key(deal)]],
          Map.has_key?(@kinds, kind) and is_number(confidence),
          do: %{
            household_id: scope.household_id,
            deal_id: deal.id,
            kind: kind,
            confidence: confidence / 1,
            inserted_at: now
          }

    {count, _} =
      Repo.insert_all(Pick, rows,
        on_conflict: :nothing,
        conflict_target: [:household_id, :deal_id]
      )

    count
  end

  defp key(%Deal{id: id}), do: "deal_#{id}"

  defp question(%Deal{} = deal) do
    what =
      [deal.product_name, deal.brand, deal.size]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(", ")

    price = if deal.price, do: " for #{Tore.Money.format(deal.price)} kr", else: ""
    condition = if deal.offer_condition, do: " (#{deal.offer_condition})", else: ""

    "How does this offer at #{deal.store} this week fit this household: " <>
      "#{what}#{price}#{condition}?"
  end

  # What Tore knows of the household, a line each, leaving out what it doesn't know yet.
  defp state(scope) do
    prefs = Household.get_preferences(scope)
    today = Tore.Clock.today()

    meals =
      scope
      |> Shop.meals_for(Streams.monday(today), today)
      |> Map.values()
      |> Enum.map(& &1.title)
      |> Enum.uniq()

    [
      "A household choosing which of this week's offers at their grocery stores to buy.",
      line("Diet", prefs.dietary_restrictions),
      line("Allergies", prefs.allergies),
      Household.Memory.snapshot(scope),
      line("This week's meals", meals),
      line("What they buy regularly", Enum.map(Basics.list(scope), & &1.name)),
      line("Bought in the last eight weeks, most often first", lately(scope, today)),
      line(
        "Their recipes",
        scope |> Recipes.list() |> Enum.map(& &1.title) |> Enum.take(@max_lines)
      )
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp line(_label, []), do: nil
  defp line(label, items), do: "#{label}: #{Enum.join(items, ", ")}."

  defp lately(scope, today) do
    since = Date.add(today, -@lately_days)

    from(li in LineItem,
      join: r in Receipt,
      on: r.id == li.receipt_id,
      where: r.date >= ^since,
      group_by: li.product_name,
      order_by: [desc: count(li.id), asc: li.product_name],
      limit: @max_lines,
      select: li.product_name
    )
    |> Repo.all(Scope.repo_opts(scope))
  end
end
