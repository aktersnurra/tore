defmodule Tore.Costs do
  alias Tore.{Planning, Repo, Scope, Streams, Costs.LLMUsage, Costs.Receipt, Costs.LineItem}
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

  # The month turns at local midnight on the 1st (`Tore.Clock`), while `inserted_at` is UTC. The
  # app has no time zone database, so the offset is the server's local time minus UTC, as it is
  # now, to the minute.
  defp month_start do
    offset_minutes =
      round(NaiveDateTime.diff(NaiveDateTime.local_now(), NaiveDateTime.utc_now()) / 60)

    Tore.Clock.today()
    |> Date.beginning_of_month()
    |> NaiveDateTime.new!(~T[00:00:00])
    |> NaiveDateTime.add(-offset_minutes, :minute)
  end

  @spec recent_receipts(Scope.t(), integer()) :: [Receipt.t()]
  def recent_receipts(%Scope{} = scope, n) do
    Repo.all(from(r in Receipt, order_by: [desc: r.date], limit: ^n), Scope.repo_opts(scope))
  end

  @doc """
  Logs a receipt and its lines. Without a `:week_start` it counts towards `receipt_week/2`'s week.
  """
  @spec log_receipt(Scope.t(), map()) :: {:ok, Receipt.t()} | {:error, term()}
  def log_receipt(%Scope{} = scope, attrs) do
    line_items = Map.get(attrs, :line_items, [])
    attrs = Map.delete(attrs, :line_items)

    attrs =
      case attrs do
        %{date: %Date{} = date} ->
          Map.put_new_lazy(attrs, :week_start, fn -> receipt_week(scope, date) end)

        _ ->
          attrs
      end

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

  @doc """
  The week a shop on `date` was for: the list ticked most recently, when that list is the date's
  week or the week after (a weekend shop for the coming week), otherwise the date's own week.
  """
  @spec receipt_week(Scope.t(), Date.t()) :: Date.t()
  def receipt_week(%Scope{} = scope, %Date{} = date) do
    own = Streams.monday(date)

    last_ticked =
      from(e in Tore.EventStore.Event,
        where: e.stream_type == "shop" and e.event_type == "ItemChecked",
        order_by: [desc: e.id],
        limit: 1,
        select: e.stream_id
      )
      |> Repo.one(Scope.repo_opts(scope))

    with id when is_binary(id) <- last_ticked,
         week = Streams.week_start(id),
         true <- week in [own, Date.add(own, 7)] do
      week
    else
      _ -> own
    end
  end

  @doc """
  Moves a receipt to the other week it can count towards: from its purchase date's week to the
  week after, or back.
  """
  @spec move_receipt_week(Scope.t(), integer()) :: {:ok, Receipt.t()} | {:error, :not_found}
  def move_receipt_week(%Scope{} = scope, id) do
    case Repo.get(Receipt, id, Scope.repo_opts(scope)) do
      nil ->
        {:error, :not_found}

      receipt ->
        own = Streams.monday(receipt.date)
        week = if receipt.week_start == own, do: Date.add(own, 7), else: own
        receipt |> Ecto.Changeset.change(week_start: week) |> Repo.update()
    end
  end

  @doc "Moves a receipt line to another of the shop's sections (`Ingredient.sections/0`)."
  @spec set_line_section(Scope.t(), integer(), String.t()) ::
          {:ok, LineItem.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_line_section(%Scope{} = scope, line_id, section) do
    from(l in LineItem, join: r in Receipt, on: r.id == l.receipt_id, where: l.id == ^line_id)
    |> Repo.one(Scope.repo_opts(scope))
    |> case do
      nil -> {:error, :not_found}
      line -> line |> LineItem.changeset(%{category: section}) |> Repo.update()
    end
  end

  @doc "What the household paid towards the week starting `week_start`, or nil with no receipt."
  @spec spent_in_week(Scope.t(), Date.t()) :: Decimal.t() | nil
  def spent_in_week(%Scope{} = scope, %Date{} = week_start) do
    from(r in Receipt,
      where: r.week_start == ^week_start,
      select: {count(r.id), sum(r.total_amount)}
    )
    |> Repo.one(Scope.repo_opts(scope))
    |> case do
      {0, _} -> nil
      {_, total} -> to_decimal(total)
    end
  end

  @doc "What was paid towards each week from `first` to `last`; a week without receipts isn't there."
  @spec spent_by_week(Scope.t(), Date.t(), Date.t()) :: %{Date.t() => Decimal.t()}
  def spent_by_week(%Scope{} = scope, %Date{} = first, %Date{} = last) do
    from(r in Receipt,
      where: r.week_start >= ^first and r.week_start <= ^last,
      group_by: r.week_start,
      select: {r.week_start, sum(r.total_amount)}
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> Map.new(fn {week, total} -> {week, to_decimal(total)} end)
  end

  @top_items 5

  @doc """
  What the lines of receipts counted towards the weeks from `first` to `last` cost, per shop
  section, biggest first. Each section has its #{@top_items} costliest items, a name counted once
  however it was printed. Lines without a price aren't counted; lines without a section are other.
  """
  @spec spending_by_section(Scope.t(), Date.t(), Date.t()) :: [
          %{
            section: String.t(),
            total: Decimal.t(),
            items: [%{name: String.t(), times: pos_integer(), total: Decimal.t()}]
          }
        ]
  def spending_by_section(%Scope{} = scope, %Date{} = first, %Date{} = last) do
    from(l in LineItem,
      join: r in Receipt,
      on: r.id == l.receipt_id,
      where: r.week_start >= ^first and r.week_start <= ^last and not is_nil(l.total_price),
      order_by: [asc: l.id],
      select: {l.category, l.product_name, l.total_price}
    )
    |> Repo.all(Scope.repo_opts(scope))
    |> Enum.group_by(fn {section, _, _} -> section || "other" end)
    |> Enum.map(fn {section, lines} ->
      items =
        lines
        |> Enum.group_by(fn {_, name, _} -> String.downcase(name) end)
        |> Enum.map(fn {_, [{_, name, _} | _] = same} ->
          %{name: name, times: length(same), total: sum(Enum.map(same, &elem(&1, 2)))}
        end)
        |> Enum.sort_by(& &1.total, {:desc, Decimal})

      %{
        section: section,
        total: sum(Enum.map(items, & &1.total)),
        items: Enum.take(items, @top_items)
      }
    end)
    |> Enum.sort_by(& &1.total, {:desc, Decimal})
  end

  defp sum(amounts), do: Enum.reduce(amounts, Decimal.new(0), &Decimal.add/2)

  @doc "A receipt with its lines, or nil."
  @spec get_receipt(Scope.t(), integer()) :: Receipt.t() | nil
  def get_receipt(%Scope{} = scope, id) do
    from(r in Receipt,
      where: r.id == ^id,
      preload: [line_items: ^from(l in LineItem, order_by: l.id)]
    )
    |> Repo.one(Scope.repo_opts(scope))
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
            total_price: receipt_to_decimal(it["total_price"]),
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
