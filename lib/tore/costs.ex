defmodule Tore.Costs do
  alias Tore.{Repo, Costs.LLMUsage, Costs.Receipt, Costs.LineItem, Costs.DiningOut}
  import Ecto.Query

  def log_llm_usage(attrs) do
    %LLMUsage{} |> LLMUsage.changeset(attrs) |> Repo.insert()
  end

  def llm_spend_this_month do
    month_start = Date.beginning_of_month(Date.utc_today())
    threshold = NaiveDateTime.new!(month_start, ~T[00:00:00])

    Repo.one(
      from u in LLMUsage,
        where: u.inserted_at >= ^threshold,
        select: coalesce(sum(u.cost_usd), 0.0)
    )
  end

  def last_llm_call(feature) do
    Repo.one(
      from u in LLMUsage,
        where: u.feature == ^to_string(feature),
        order_by: [desc: u.inserted_at],
        limit: 1
    )
  end

  def llm_spend_last_30_days do
    threshold = NaiveDateTime.add(NaiveDateTime.utc_now(), -30 * 24 * 3600)

    Repo.one(
      from u in LLMUsage,
        where: u.inserted_at >= ^threshold,
        select: coalesce(sum(u.cost_usd), 0.0)
    )
  end

  def llm_spend_total do
    Repo.one(from u in LLMUsage, select: coalesce(sum(u.cost_usd), 0.0))
  end

  def llm_calls_this_month_by_feature do
    month_start = Date.beginning_of_month(Date.utc_today())
    threshold = NaiveDateTime.new!(month_start, ~T[00:00:00])

    Repo.all(
      from u in LLMUsage,
        where: u.inserted_at >= ^threshold,
        group_by: u.feature,
        select: {u.feature, count(u.id), coalesce(sum(u.cost_usd), 0.0)}
    )
  end

  @spec list_receipts() :: [Receipt.t()]
  def list_receipts do
    Repo.all(from r in Receipt, order_by: [desc: r.date], limit: 50)
  end

  @spec recent_receipts(integer()) :: [Receipt.t()]
  def recent_receipts(n) do
    Repo.all(from r in Receipt, order_by: [desc: r.date], limit: ^n)
  end

  @spec receipts_by_store(integer(), integer()) :: [
          %{store: String.t(), count: integer(), total: Decimal.t()}
        ]
  def receipts_by_store(year, month) do
    {:ok, month_start} = Date.new(year, month, 1)
    month_end = Date.end_of_month(month_start)

    Repo.all(
      from r in Receipt,
        where: r.date >= ^month_start and r.date <= ^month_end,
        group_by: r.store_name,
        select: %{
          store: r.store_name,
          count: count(r.id),
          total: coalesce(sum(r.total_amount), 0)
        },
        order_by: [desc: coalesce(sum(r.total_amount), 0)]
    )
  end

  @spec weekly_spend_this_month(Date.t()) :: [%{week: integer(), total: Decimal.t()}]
  def weekly_spend_this_month(today) do
    month_start = Date.beginning_of_month(today)
    month_end = Date.end_of_month(today)

    rows =
      Repo.all(
        from r in Receipt,
          where: r.date >= ^month_start and r.date <= ^month_end,
          select: {r.date, r.total_amount}
      )

    rows
    |> Enum.group_by(fn {date, _} ->
      week_of_month(date, month_start)
    end)
    |> Enum.map(fn {week, entries} ->
      total =
        Enum.reduce(entries, Decimal.new(0), fn {_, amt}, acc ->
          Decimal.add(acc, amt || Decimal.new(0))
        end)

      %{week: week, total: total}
    end)
    |> Enum.sort_by(& &1.week)
  end

  defp week_of_month(date, month_start) do
    div(Date.diff(date, month_start), 7) + 1
  end

  @spec log_receipt(map()) :: {:ok, Receipt.t()} | {:error, term()}
  def log_receipt(attrs) do
    line_items = Map.get(attrs, :line_items, [])
    attrs = Map.delete(attrs, :line_items)

    Repo.transaction(fn ->
      case %Receipt{} |> Receipt.changeset(attrs) |> Repo.insert() do
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

  @spec log_dining_out(map()) :: {:ok, DiningOut.t()} | {:error, term()}
  def log_dining_out(attrs) do
    %DiningOut{} |> DiningOut.changeset(attrs) |> Repo.insert()
  end

  def log_dining_out(attrs, user_id) do
    log_dining_out(Map.put(attrs, :user_id, user_id))
  end

  def parse_receipt_image(image_binary) do
    parse_receipt(image_binary, nil)
  end

  def parse_receipt(image_binary, locale) do
    {system, user} = Tore.LLM.Prompts.parse_receipt_for_pantry(locale)

    with {:ok, data, _usage} <-
           Tore.LLM.vision([{:image, image_binary}], system, user,
             response_format: Tore.LLM.Prompts.receipt_pantry_json_schema()
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

  defp parse_iso_date(nil), do: nil

  defp parse_iso_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_iso_date(_), do: nil

  def parse_and_log_receipt(image_binary, user_id) do
    image_path = store_receipt_image(image_binary)
    {system, user} = Tore.LLM.Prompts.parse_receipt()

    with {:ok, data, _usage} <-
           Tore.LLM.vision([{:image, image_binary}], system, user,
             response_format: Tore.LLM.Prompts.receipt_json_schema()
           ) do
      line_items =
        Enum.map(data["line_items"] || [], fn it ->
          %{
            product_name: it["product_name"],
            quantity: receipt_to_decimal(it["quantity"]),
            unit_price: receipt_to_decimal(it["unit_price"]),
            total_price: receipt_to_decimal(it["total_price"]),
            category: it["category"]
          }
        end)

      total =
        line_items
        |> Enum.map(fn item -> item.total_price || Decimal.new(0) end)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

      log_receipt(%{
        date: Date.utc_today(),
        image_path: image_path,
        total_amount: total,
        user_id: user_id,
        line_items: line_items
      })
    end
  end

  def confirm_receipt(%{total: total, store_name: store_name, date: date}, user_id) do
    log_receipt(%{
      date: date,
      store_name: store_name,
      total_amount: receipt_to_decimal(total),
      user_id: user_id,
      line_items: []
    })
  end

  @spec list_dining_out() :: [DiningOut.t()]
  def list_dining_out do
    Repo.all(from d in DiningOut, order_by: [desc: d.date], limit: 50)
  end

  @spec dining_by_place() :: [%{place: String.t(), count: integer(), total: Decimal.t()}]
  def dining_by_place do
    Repo.all(
      from d in DiningOut,
        group_by: d.description,
        select: %{
          place: d.description,
          count: count(d.id),
          total: coalesce(sum(d.total_amount), 0)
        },
        order_by: [desc: count(d.id)]
    )
  end

  @spec monthly_total(integer(), integer()) :: Decimal.t()
  def monthly_total(year, month) do
    {:ok, month_start} = Date.new(year, month, 1)
    month_end = Date.end_of_month(month_start)

    grocery =
      Repo.one(
        from r in Receipt,
          where: r.date >= ^month_start and r.date <= ^month_end,
          select: coalesce(sum(r.total_amount), 0)
      )
      |> to_decimal()

    dining =
      Repo.one(
        from d in DiningOut,
          where: d.date >= ^month_start and d.date <= ^month_end,
          select: coalesce(sum(d.total_amount), 0)
      )
      |> to_decimal()

    Decimal.add(grocery, dining)
  end

  @spec weekly_summary(Date.t()) :: {:ok, map()}
  def weekly_summary(week_start) do
    week_end = Date.add(week_start, 6)

    grocery =
      Repo.one(
        from r in Receipt,
          where: r.date >= ^week_start and r.date <= ^week_end,
          select: coalesce(sum(r.total_amount), 0)
      )
      |> to_decimal()

    dining =
      Repo.one(
        from d in DiningOut,
          where: d.date >= ^week_start and d.date <= ^week_end,
          select: coalesce(sum(d.total_amount), 0)
      )
      |> to_decimal()

    {:ok, %{grocery_total: grocery, dining_total: dining, total: Decimal.add(grocery, dining)}}
  end

  @spec monthly_summary(integer(), integer()) :: {:ok, map()}
  def monthly_summary(year, month) do
    {:ok, month_start} = Date.new(year, month, 1)
    month_end = Date.end_of_month(month_start)

    grocery =
      Repo.one(
        from r in Receipt,
          where: r.date >= ^month_start and r.date <= ^month_end,
          select: coalesce(sum(r.total_amount), 0)
      )
      |> to_decimal()

    receipt_count =
      Repo.one(
        from r in Receipt,
          where: r.date >= ^month_start and r.date <= ^month_end,
          select: count(r.id)
      )

    dining =
      Repo.one(
        from d in DiningOut,
          where: d.date >= ^month_start and d.date <= ^month_end,
          select: coalesce(sum(d.total_amount), 0)
      )
      |> to_decimal()

    dining_count =
      Repo.one(
        from d in DiningOut,
          where: d.date >= ^month_start and d.date <= ^month_end,
          select: count(d.id)
      )

    {:ok,
     %{
       grocery_total: grocery,
       dining_total: dining,
       total: Decimal.add(grocery, dining),
       receipt_count: receipt_count,
       dining_count: dining_count
     }}
  end

  defp receipt_to_decimal(nil), do: nil
  defp receipt_to_decimal(%Decimal{} = d), do: d
  defp receipt_to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp receipt_to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp receipt_to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp store_receipt_image(binary) do
    filename = "#{System.unique_integer([:positive])}.jpg"
    dir = Path.join([:code.priv_dir(:tore), "static", "uploads", "receipts"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), binary)
    "/uploads/receipts/#{filename}"
  end

  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)

  @spec cost_per_meal(map()) :: {:ok, Decimal.t()} | {:error, term()}
  def cost_per_meal(%{week_start: week_start, meal_count: meal_count}) when meal_count > 0 do
    {:ok, %{grocery_total: total}} = weekly_summary(week_start)
    {:ok, Decimal.div(total, meal_count)}
  end

  def cost_per_meal(_), do: {:error, :invalid_period}
end
