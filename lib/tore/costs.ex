defmodule Tore.Costs do
  alias Tore.{Planning, Repo, Scope, Costs.LLMUsage, Costs.Receipt, Costs.LineItem}
  import Ecto.Query

  @doc "Records what an LLM call cost the household. Only `Tore.LLM` calls this, after each call."
  @spec log_llm_usage(Scope.t(), map()) :: {:ok, LLMUsage.t()} | {:error, Ecto.Changeset.t()}
  def log_llm_usage(%Scope{} = scope, attrs) do
    %LLMUsage{household_id: scope.household_id} |> LLMUsage.changeset(attrs) |> Repo.insert()
  end

  @spec llm_spend_this_month(Scope.t()) :: float()
  def llm_spend_this_month(%Scope{} = scope) do
    from(u in LLMUsage,
      where: u.inserted_at >= ^month_start(),
      select: coalesce(sum(u.cost_usd), 0.0)
    )
    |> Repo.one(Scope.repo_opts(scope))
  end

  def last_llm_call(%Scope{} = scope, feature) do
    from(u in LLMUsage,
      where: u.feature == ^to_string(feature),
      order_by: [desc: u.inserted_at],
      limit: 1
    )
    |> Repo.one(Scope.repo_opts(scope))
  end

  def llm_spend_last_30_days(%Scope{} = scope) do
    threshold = NaiveDateTime.add(NaiveDateTime.utc_now(), -30 * 24 * 3600)

    from(u in LLMUsage,
      where: u.inserted_at >= ^threshold,
      select: coalesce(sum(u.cost_usd), 0.0)
    )
    |> Repo.one(Scope.repo_opts(scope))
  end

  def llm_spend_total(%Scope{} = scope) do
    Repo.one(from(u in LLMUsage, select: coalesce(sum(u.cost_usd), 0.0)), Scope.repo_opts(scope))
  end

  def llm_calls_this_month_by_feature(%Scope{} = scope) do
    from(u in LLMUsage,
      where: u.inserted_at >= ^month_start(),
      group_by: u.feature,
      select: {u.feature, count(u.id), coalesce(sum(u.cost_usd), 0.0)}
    )
    |> Repo.all(Scope.repo_opts(scope))
  end

  defp month_start do
    Date.utc_today() |> Date.beginning_of_month() |> NaiveDateTime.new!(~T[00:00:00])
  end

  @spec recent_receipts(Scope.t(), integer()) :: [Receipt.t()]
  def recent_receipts(%Scope{} = scope, n) do
    Repo.all(from(r in Receipt, order_by: [desc: r.date], limit: ^n), Scope.repo_opts(scope))
  end

  @spec log_receipt(Scope.t(), map()) :: {:ok, Receipt.t()} | {:error, term()}
  def log_receipt(%Scope{} = scope, attrs) do
    line_items = Map.get(attrs, :line_items, [])
    attrs = Map.delete(attrs, :line_items)

    Repo.transaction(fn ->
      case %Receipt{household_id: scope.household_id}
           |> Receipt.changeset(attrs)
           |> Repo.insert() do
        {:ok, receipt} ->
          Enum.each(line_items, fn item ->
            %LineItem{}
            |> LineItem.changeset(Map.put(item, :receipt_id, receipt.id))
            |> Repo.insert!()
          end)

          receipt

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def parse_receipt(%Scope{} = scope, image_binary, locale) do
    {system, user} = Tore.LLM.Prompts.parse_receipt(locale)

    with {:ok, data, _usage} <-
           Tore.LLM.vision(scope, [{:image, image_binary}], system, user,
             response_format: Tore.LLM.Prompts.receipt_json_schema(),
             feature: :parse_receipt
           ) do
      items =
        Enum.map(data["items"] || [], fn it ->
          %{
            name: it["name"],
            quantity: receipt_to_decimal(it["quantity"]),
            unit: it["unit"],
            category: it["category"]
          }
        end)

      {:ok,
       %{
         total: receipt_to_decimal(data["total"]),
         store_name: data["store_name"],
         purchase_date: parse_iso_date(data["purchase_date"]),
         items: items
       }}
    end
  end

  @doc "Deletes a receipt and its line items. Undoing a receipt run does this."
  @spec delete_receipt(Scope.t(), integer()) :: :ok | {:error, :not_found}
  def delete_receipt(%Scope{} = scope, id) do
    case Repo.delete_all(from(r in Receipt, where: r.id == ^id), Scope.repo_opts(scope)) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  defp parse_iso_date(nil), do: nil

  defp parse_iso_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_iso_date(_), do: nil

  @doc "The days eaten out in a month, newest first, as the plans hold them: `%{date, place, amount}`."
  @spec eating_out_in_month(Scope.t(), integer(), integer()) :: [map()]
  def eating_out_in_month(%Scope{} = scope, year, month) do
    {:ok, month_start} = Date.new(year, month, 1)

    scope
    |> Planning.eating_out_between(month_start, Date.end_of_month(month_start))
    |> Enum.reverse()
  end

  @spec monthly_total(Scope.t(), integer(), integer()) :: Decimal.t()
  def monthly_total(%Scope{} = scope, year, month) do
    {:ok, month_start} = Date.new(year, month, 1)
    month_end = Date.end_of_month(month_start)

    grocery =
      Repo.one(
        from(r in Receipt,
          where: r.date >= ^month_start and r.date <= ^month_end,
          select: coalesce(sum(r.total_amount), 0)
        ),
        Scope.repo_opts(scope)
      )
      |> to_decimal()

    dining =
      scope
      |> eating_out_in_month(year, month)
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount || 0))

    Decimal.add(grocery, dining)
  end

  defp receipt_to_decimal(nil), do: nil
  defp receipt_to_decimal(%Decimal{} = d), do: d
  defp receipt_to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp receipt_to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp receipt_to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
end
