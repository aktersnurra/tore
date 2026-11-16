defmodule ToreWeb.Spending do
  @moduledoc """
  What the household spent on food this month, under the shopping list: the month's total
  against last month's, the latest receipts, eating out, and a receipt photo to scan. Shop owns
  the upload and the reading (`ToreWeb.ShopLive`); this only draws it.
  """

  use ToreWeb, :html

  alias Tore.Costs

  @recent_receipts 5

  @doc "This month's figures for the household, as `spending/1` takes them."
  @spec load(Tore.Scope.t()) :: map()
  def load(scope) do
    today = Tore.Clock.today()
    last_month = today |> Date.beginning_of_month() |> Date.add(-1)
    total = Costs.monthly_total(scope, today.year, today.month)
    last = Costs.monthly_total(scope, last_month.year, last_month.month)

    %{
      month_total: total,
      month_change: change(total, last),
      receipts: Costs.recent_receipts(scope, @recent_receipts),
      dining: Costs.eating_out_in_month(scope, today.year, today.month)
    }
  end

  defp change(total, last) do
    if Decimal.gt?(last, 0) do
      total
      |> Decimal.sub(last)
      |> Decimal.mult(100)
      |> Decimal.div(last)
      |> Decimal.round(0)
      |> Decimal.to_integer()
    end
  end

  attr :spending, :map, required: true
  attr :scanning, :boolean, required: true
  attr :upload, :any, required: true, doc: "the receipt photo upload"

  def spending(assigns) do
    ~H"""
    <section id="spending" class="mt-12">
      <div class="flex items-end justify-between gap-3">
        <div class="min-w-0">
          <h2 class="t-eyebrow">{gettext("Spent this month")}</h2>
          <p id="month-total" class="t-title num mt-1">
            {money(@spending.month_total)} kr
          </p>
          <p
            :if={@spending.month_change}
            class="num mt-0.5 text-[color:var(--muted)]"
            style="font-size: var(--t-meta);"
          >
            {gettext("%{change} compared with last month",
              change: signed_percent(@spending.month_change)
            )}
          </p>
        </div>
        <form id="receipt-photo-form" phx-change="validate_upload" class="shrink-0">
          <.live_file_input upload={@upload} class="hidden" />
          <label
            :if={!@scanning}
            for={@upload.ref}
            class="pill press cursor-pointer"
          >
            <.icon name="hero-camera" /> {gettext("Scan receipt")}
          </label>
          <span
            :if={@scanning}
            role="status"
            class="inline-flex h-11 items-center gap-2 text-[14px] text-[color:var(--muted)]"
          >
            <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" /> {gettext(
              "Reading the receipt…"
            )}
          </span>
        </form>
      </div>

      <ul :if={@spending.receipts != [] or @spending.dining != []} class="menu-lines mt-4">
        <.spent_row
          :for={r <- @spending.receipts}
          title={r.store_name || gettext("Unknown store")}
          date={r.date}
          amount={r.total_amount}
        />
        <.spent_row
          :for={d <- @spending.dining}
          title={d.place || gettext("Eating out")}
          date={d.date}
          amount={d.amount}
        />
      </ul>
      <p
        :if={@spending.receipts == [] and @spending.dining == []}
        class="mt-3 text-[color:var(--muted)]"
        style="font-size: var(--t-meta);"
      >
        {gettext("No receipts yet. Scan one after you shop.")}
      </p>
    </section>
    """
  end

  attr :title, :string, required: true
  attr :date, Date, required: true
  attr :amount, :any, required: true

  defp spent_row(assigns) do
    ~H"""
    <li class="flex items-center gap-4 px-4 py-3">
      <span class="min-w-0 flex-1">
        <span class="block truncate text-[color:var(--text)]" style="font-size: var(--t-body);">
          {@title}
        </span>
        <span class="mt-0.5 block text-[color:var(--muted)]" style="font-size: var(--t-meta);">
          {Calendar.strftime(@date, "%-d/%-m")}
        </span>
      </span>
      <span :if={@amount} class="num text-[color:var(--muted)]" style="font-size: var(--t-meta);">
        {money(@amount)} kr
      </span>
    </li>
    """
  end

  defp signed_percent(n) when n > 0, do: "+#{n}%"
  defp signed_percent(n), do: "#{n}%"

  defp money(%Decimal{} = amount), do: Tore.Money.format(amount)
end
