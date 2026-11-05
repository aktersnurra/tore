defmodule ToreWeb.SettingsLive do
  use ToreWeb, :live_view

  alias Tore.{Accounts, Costs, Household}

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
       new_user_name: "",
       revealed_codes: %{},
       add_error: nil,
       ai: ai,
       memory_insights: Household.list_active_insights(),
       household: Household.get_household!(),
       locales: Household.supported_locales()
     )}
  end

  def handle_event("update_locale", %{"locale" => locale}, socket) do
    case Household.update_household(%{locale: locale}) do
      {:ok, household} -> {:noreply, assign(socket, household: household)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("add_user", _params, %{assigns: %{current_user: %{role: role}}} = socket)
      when role != :admin,
      do: {:noreply, socket}

  def handle_event("add_user", %{"name" => name}, socket) do
    case Accounts.create_user(%{name: String.trim(name)}) do
      {:ok, {user, code}} ->
        users = Accounts.list_users()
        revealed = Map.put(socket.assigns.revealed_codes, user.id, format_code(code))

        {:noreply,
         assign(socket, users: users, new_user_name: "", revealed_codes: revealed, add_error: nil)}

      {:error, _} ->
        {:noreply, assign(socket, add_error: gettext("Could not create user."))}
    end
  end

  def handle_event(
        "regenerate_code",
        _params,
        %{assigns: %{current_user: %{role: role}}} = socket
      )
      when role != :admin,
      do: {:noreply, socket}

  def handle_event("regenerate_code", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    case Accounts.regenerate_code(user) do
      {:ok, {_updated, code}} ->
        revealed = Map.put(socket.assigns.revealed_codes, user.id, format_code(code))
        {:noreply, assign(socket, revealed_codes: revealed)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("dismiss_code", %{"id" => id}, socket) do
    revealed = Map.delete(socket.assigns.revealed_codes, String.to_integer(id))
    {:noreply, assign(socket, revealed_codes: revealed)}
  end

  def handle_event("forget_insight", %{"id" => id}, socket) do
    Tore.Household.dismiss_insight(String.to_integer(id))
    {:noreply, assign(socket, memory_insights: Tore.Household.list_active_insights())}
  end

  defp format_code(code) do
    code
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(" ")
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

          <%!-- Users --%>
          <section class="px-6 pt-3 pb-5 border-t border-[color:var(--hairline)]">
            <h2
              class="uppercase tracking-wider text-[color:var(--subtle)] mb-3"
              style="font-size: var(--t-micro); font-weight: 600;"
            >
              {gettext("Users")}
            </h2>

            <div class="flex flex-col gap-3">
              <div :for={user <- @users} class="flex items-center gap-3">
                <span
                  class="size-9 rounded-full bg-[color:var(--accent-soft)] text-[color:var(--accent-ink)] inline-flex items-center justify-center font-semibold shrink-0"
                  style="font-size: var(--t-meta);"
                >
                  {String.first(user.name || "?")}
                </span>
                <div class="flex-1 min-w-0">
                  <p class="font-medium text-[var(--text)] truncate" style="font-size: var(--t-body);">
                    {user.name}
                  </p>
                  <p class="text-[color:var(--muted)] capitalize" style="font-size: var(--t-meta);">
                    {user.role}
                  </p>
                </div>
                <div
                  :if={@current_user.role == :admin and Map.has_key?(@revealed_codes, user.id)}
                  class="flex items-center gap-2"
                >
                  <code
                    class="bg-[color:var(--accent-soft)] text-[color:var(--accent-ink)] px-2 py-0.5 rounded font-mono"
                    style="font-size: var(--t-meta);"
                  >
                    {Map.get(@revealed_codes, user.id)}
                  </code>
                  <button
                    type="button"
                    phx-click="dismiss_code"
                    phx-value-id={user.id}
                    class="text-[color:var(--muted)] hover:text-[var(--text)]"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
                <button
                  :if={@current_user.role == :admin and not Map.has_key?(@revealed_codes, user.id)}
                  type="button"
                  phx-click="regenerate_code"
                  phx-value-id={user.id}
                  class="inline-flex items-center gap-1 text-[color:var(--accent)] hover:underline shrink-0"
                  style="font-size: var(--t-meta);"
                >
                  <.icon name="hero-arrow-path" class="size-3.5" />{gettext("New code")}
                </button>
              </div>
            </div>

            <form
              :if={@current_user.role == :admin}
              phx-submit="add_user"
              class="mt-4 flex items-center gap-2"
            >
              <input
                type="text"
                name="name"
                value={@new_user_name}
                placeholder={gettext("Name")}
                required
                class="flex-1 rounded-lg border border-[color:var(--hairline)] bg-[color:var(--surface)] px-3 py-1.5 text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)]"
                style="font-size: var(--t-body);"
              />
              <.button type="submit" variant={:primary}>
                <.icon name="hero-plus" class="size-4" />{gettext("Add user")}
              </.button>
            </form>
            <p
              :if={@add_error}
              class="mt-1 text-[color:var(--danger)]"
              style="font-size: var(--t-meta);"
            >
              {@add_error}
            </p>
          </section>

          <%!-- Household --%>
          <section class="px-6 pt-5 pb-5 border-t border-[color:var(--hairline)]">
            <h2
              class="uppercase tracking-wider text-[color:var(--subtle)] mb-3"
              style="font-size: var(--t-micro); font-weight: 600;"
            >
              {gettext("Household")}
            </h2>
            <form phx-change="update_locale" class="flex items-center justify-between gap-3">
              <div class="flex-1 min-w-0">
                <p class="font-medium text-[var(--text)]" style="font-size: var(--t-body);">
                  {gettext("Language")}
                </p>
                <p class="text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                  {gettext("Used for reading receipts, recipes and grocery labels.")}
                </p>
              </div>
              <select
                name="locale"
                class="rounded-lg border border-[color:var(--hairline)] bg-[var(--surface)] px-3 py-1.5 text-[var(--text)] focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)]"
                style="font-size: var(--t-body);"
              >
                <option
                  :for={{code, label} <- @locales}
                  value={code}
                  selected={code == @household.locale}
                >
                  {label}
                </option>
              </select>
            </form>
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
            <li>
              <.link
                navigate={~p"/inbox"}
                class="flex items-center justify-between p-4 hover:bg-stone-50"
              >
                <span>{gettext("Run history")}</span>
                <span aria-hidden="true">→</span>
              </.link>
            </li>
          </ul>
        </section>
      </.page>
    </Layouts.app>
    """
  end
end
