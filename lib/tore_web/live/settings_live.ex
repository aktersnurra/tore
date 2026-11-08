defmodule ToreWeb.SettingsLive do
  use ToreWeb, :live_view

  alias Tore.{Accounts, Costs, Deals, Household}

  def mount(_params, _session, socket) do
    users = Accounts.list_users()

    ai = %{
      this_month: Costs.llm_spend_this_month(),
      last_30_days: Costs.llm_spend_last_30_days(),
      total: Costs.llm_spend_total(),
      by_feature: Costs.llm_calls_this_month_by_feature()
    }

    {:ok,
     assign(socket,
       users: users,
       ai: ai,
       memory_insights: Household.list_active_insights(socket.assigns.current_scope),
       household: Household.get!(socket.assigns.current_scope),
       stores: Deals.list_stores(socket.assigns.current_scope),
       store_url: "",
       store_error: nil
     )}
  end

  def handle_event("add_store", %{"url" => url}, socket) do
    case Deals.add_store(socket.assigns.current_scope, url) do
      {:ok, _store} ->
        {:noreply,
         assign(socket,
           stores: Deals.list_stores(socket.assigns.current_scope),
           store_url: "",
           store_error: nil
         )}

      {:error, :unsupported_store} ->
        {:noreply,
         assign(socket, store_url: url, store_error: gettext("Tore can't read that store yet"))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         assign(socket, store_url: url, store_error: gettext("That store is already added"))}
    end
  end

  def handle_event("toggle_store", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    {:ok, _store} = Deals.toggle_scraping(scope, String.to_integer(id))
    {:noreply, assign(socket, stores: Deals.list_stores(scope))}
  end

  def handle_event("remove_store", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    {:ok, _store} = Deals.remove_store(scope, String.to_integer(id))
    {:noreply, assign(socket, stores: Deals.list_stores(scope))}
  end

  def handle_event("forget_insight", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    Tore.Household.dismiss_insight(scope, String.to_integer(id))
    {:noreply, assign(socket, memory_insights: Tore.Household.list_active_insights(scope))}
  end

  defp format_usd(nil), do: "$0.00"
  defp format_usd(v), do: "$#{:erlang.float_to_binary(v / 1, decimals: 2)}"

  defp confidence_label(c) when c >= 0.8, do: gettext("High confidence")
  defp confidence_label(c) when c >= 0.5, do: gettext("Medium confidence")
  defp confidence_label(_c), do: gettext("Low confidence")

  defp feature_label("generate_plan"), do: gettext("Plan generation")
  defp feature_label("prep_guide"), do: gettext("Prep guide")
  defp feature_label("parse_receipt"), do: gettext("Receipt parsing")
  defp feature_label("extract_recipe"), do: gettext("Recipe import")
  defp feature_label("suggest_recipe"), do: gettext("Recipe suggestions")
  defp feature_label(f), do: f

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={assigns[:current_path] || "/settings"}>
      <.page max_width={:md}>
        <.card padded={false}>
          <header class="px-6 pt-6 pb-3">
            <h1 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h1);">
              {gettext("Settings")}
            </h1>
          </header>

          <%!-- Members --%>
          <section class="px-6 pt-3 pb-5 border-t border-[color:var(--hairline)]">
            <h2
              class="uppercase tracking-wider text-[color:var(--subtle)] mb-3"
              style="font-size: var(--t-micro); font-weight: 600;"
            >
              {gettext("Members")}
            </h2>

            <div class="flex flex-col gap-3">
              <div :for={user <- @users} class="flex items-center gap-3">
                <span
                  class="size-9 rounded-full bg-[color:var(--accent-soft)] text-[color:var(--accent-ink)] inline-flex items-center justify-center font-semibold shrink-0"
                  style="font-size: var(--t-meta);"
                >
                  {String.first(user.name)}
                </span>
                <div class="flex-1 min-w-0">
                  <p class="font-medium text-[var(--text)] truncate" style="font-size: var(--t-body);">
                    {user.name}
                  </p>
                  <p class="text-[color:var(--muted)] truncate" style="font-size: var(--t-meta);">
                    {user.username}
                  </p>
                </div>
              </div>
            </div>

            <.link
              href={~p"/logout"}
              method="delete"
              class="mt-4 inline-block text-[color:var(--accent)] hover:underline"
              style="font-size: var(--t-meta);"
            >
              {gettext("Sign out")}
            </.link>
          </section>

          <%!-- Household --%>
          <section class="px-6 pt-5 pb-5 border-t border-[color:var(--hairline)]">
            <h2
              class="uppercase tracking-wider text-[color:var(--subtle)] mb-3"
              style="font-size: var(--t-micro); font-weight: 600;"
            >
              {gettext("Household")}
            </h2>
            <div class="flex items-center justify-between gap-3">
              <div class="flex-1 min-w-0">
                <p class="font-medium text-[var(--text)]" style="font-size: var(--t-body);">
                  {gettext("Language")}
                </p>
                <p class="text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                  {gettext("Used for reading receipts, recipes and grocery labels. Chosen once.")}
                </p>
              </div>
              <p class="text-[var(--text)]" style="font-size: var(--t-body);">
                {Household.locale_label(@household.locale)}
              </p>
            </div>
          </section>

          <%!-- Device tokens --%>
          <%!-- Kitchen memory --%>
          <section class="px-6 pt-5 pb-5 border-t border-[color:var(--hairline)]">
            <h2
              class="uppercase tracking-wider text-[color:var(--subtle)] mb-3"
              style="font-size: var(--t-micro); font-weight: 600;"
            >
              {gettext("Things Tore has learned")}
            </h2>
            <%= if Enum.empty?(@memory_insights) do %>
              <p class="text-sm text-zinc-500">
                {gettext("No memories yet. Tore learns as you cook.")}
              </p>
            <% else %>
              <ul class="space-y-2">
                <%= for insight <- @memory_insights do %>
                  <li class="flex items-start justify-between gap-3 rounded-lg border border-zinc-200 p-3">
                    <div class="flex-1">
                      <p class="text-sm">{insight.body}</p>
                      <span class="mt-1 inline-block rounded-full bg-zinc-100 px-2 py-0.5 text-xs text-zinc-500">
                        {confidence_label(insight.confidence)}
                      </span>
                    </div>
                    <button
                      phx-click="forget_insight"
                      phx-value-id={insight.id}
                      class="text-xs text-red-500 hover:text-red-700 shrink-0 mt-0.5"
                    >
                      {gettext("Forget")}
                    </button>
                  </li>
                <% end %>
              </ul>
            <% end %>
          </section>

          <%!-- Stores --%>
          <section class="px-6 pt-5 pb-5 border-t border-[color:var(--hairline)]">
            <h2
              class="uppercase tracking-wider text-[color:var(--subtle)] mb-3"
              style="font-size: var(--t-micro); font-weight: 600;"
            >
              {gettext("Stores")}
            </h2>

            <div :if={@stores != []} class="flex flex-col gap-3 mb-4">
              <div :for={store <- @stores} class="flex items-center gap-3">
                <p
                  class="flex-1 min-w-0 font-medium text-[var(--text)] truncate"
                  style="font-size: var(--t-body);"
                >
                  {store.store.name}
                </p>
                <button
                  type="button"
                  role="switch"
                  aria-checked={to_string(store.scrape_enabled)}
                  phx-click="toggle_store"
                  phx-value-id={store.id}
                  class={[
                    "font-medium hover:underline",
                    store.scrape_enabled && "text-[color:var(--accent)]",
                    !store.scrape_enabled && "text-[color:var(--muted)]"
                  ]}
                  style="font-size: var(--t-meta);"
                >
                  {if store.scrape_enabled, do: gettext("On"), else: gettext("Off")}
                </button>
                <button
                  type="button"
                  phx-click="remove_store"
                  phx-value-id={store.id}
                  class="text-[color:var(--danger)] hover:underline"
                  style="font-size: var(--t-meta);"
                >
                  {gettext("Remove")}
                </button>
              </div>
            </div>

            <form phx-submit="add_store" class="flex items-center gap-2">
              <input
                type="url"
                name="url"
                value={@store_url}
                placeholder="https://www.ica.se/erbjudanden/…"
                aria-label={gettext("Link to a store's offers")}
                required
                class="flex-1 min-w-0 rounded-lg border border-[color:var(--hairline)] bg-[color:var(--surface)] px-3 py-2"
                style="font-size: var(--t-body);"
              />
              <.button type="submit" variant={:primary}>
                <.icon name="hero-plus" class="size-4" />{gettext("Add")}
              </.button>
            </form>
            <p
              :if={@store_error}
              class="mt-1 text-[color:var(--danger)]"
              style="font-size: var(--t-meta);"
            >
              {@store_error}
            </p>
          </section>

          <%!-- AI usage --%>
          <section class="px-6 pt-5 pb-5 border-t border-[color:var(--hairline)]">
            <h2
              class="uppercase tracking-wider text-[color:var(--subtle)] mb-3"
              style="font-size: var(--t-micro); font-weight: 600;"
            >
              {gettext("AI usage")}
            </h2>
            <div class="flex flex-col gap-2">
              <div class="flex justify-between">
                <span class="text-[color:var(--muted)]" style="font-size: var(--t-body);">
                  {gettext("This month")}
                </span>
                <span class="font-medium tabular-nums" style="font-size: var(--t-body);">
                  {format_usd(@ai.this_month)}
                </span>
              </div>
              <div class="flex justify-between">
                <span class="text-[color:var(--muted)]" style="font-size: var(--t-body);">
                  {gettext("Last 30 days")}
                </span>
                <span class="font-medium tabular-nums" style="font-size: var(--t-body);">
                  {format_usd(@ai.last_30_days)}
                </span>
              </div>
              <div class="flex justify-between">
                <span class="text-[color:var(--muted)]" style="font-size: var(--t-body);">
                  {gettext("Total")}
                </span>
                <span class="font-medium tabular-nums" style="font-size: var(--t-body);">
                  {format_usd(@ai.total)}
                </span>
              </div>
            </div>
            <div
              :if={@ai.by_feature != []}
              class="mt-3 pt-3 border-t border-[color:var(--hairline)] flex flex-col gap-1.5"
            >
              <p class="text-[color:var(--subtle)] mb-1" style="font-size: var(--t-micro);">
                {gettext("This month by feature")}
              </p>
              <div
                :for={{feature, calls, cost} <- @ai.by_feature}
                class="flex justify-between items-center"
              >
                <span class="text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                  {feature_label(feature)}
                </span>
                <span class="text-[color:var(--muted)] tabular-nums" style="font-size: var(--t-meta);">
                  {calls}× · {format_usd(cost)}
                </span>
              </div>
            </div>
          </section>
        </.card>

        <section class="mt-8 border-t border-stone-200 pt-6">
          <h2 class="text-sm font-semibold text-stone-500 uppercase tracking-widest mb-3">
            {gettext("More")}
          </h2>
          <ul class="divide-y divide-stone-200 rounded-lg border border-stone-200 bg-white">
            <li>
              <.link
                navigate={~p"/settings/pantry"}
                class="flex items-center justify-between p-4 hover:bg-stone-50"
              >
                <span>{gettext("Approximate inventory")}</span>
                <span aria-hidden="true">→</span>
              </.link>
            </li>
            <li>
              <.link
                navigate={~p"/settings/costs"}
                class="flex items-center justify-between p-4 hover:bg-stone-50"
              >
                <span>{gettext("Spending")}</span>
                <span aria-hidden="true">→</span>
              </.link>
            </li>
            <li></li>
          </ul>
        </section>
      </.page>
    </Layouts.app>
    """
  end
end
