defmodule ToreWeb.SettingsLive do
  use ToreWeb, :live_view

  alias Tore.Household.Memory
  alias Tore.{Accounts, Costs, Deals, Household, Members}
  alias ToreWeb.UserSession

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    ai = %{
      this_month: Costs.llm_spend_this_month(scope),
      last_30_days: Costs.llm_spend_last_30_days(scope),
      total: Costs.llm_spend_total(scope),
      by_feature: Costs.llm_calls_this_month_by_feature(scope)
    }

    {:ok,
     socket
     |> assign_members()
     |> assign_ai_sponsor()
     |> assign(
       member_username: "",
       member_notice: nil,
       member_error: nil,
       households: Members.list_households(socket.assigns.current_user),
       ai: ai,
       memory: Memory.stores(socket.assigns.current_scope),
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
    _ = Deals.toggle_scraping(scope, String.to_integer(id))
    {:noreply, assign(socket, stores: Deals.list_stores(scope))}
  end

  def handle_event("remove_store", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    _ = Deals.remove_store(scope, String.to_integer(id))
    {:noreply, assign(socket, stores: Deals.list_stores(scope))}
  end

  def handle_event("add_member", %{"username" => username}, socket) do
    case Members.add(socket.assigns.current_scope, username) do
      {:ok, result} ->
        notice =
          case result do
            {:pending, name} ->
              gettext("%{name} joins at their first sign-in.", name: name)

            {:moved, user} ->
              # Their empty household is gone, so their open pages move here.
              UserSession.disconnect(user.id)
              gettext("%{name} is now a member.", name: user.name)

            {:added, user} ->
              gettext("%{name} is now a member.", name: user.name)
          end

        {:noreply,
         socket
         |> assign_members()
         |> assign(member_username: "", member_notice: notice, member_error: nil)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           member_username: username,
           member_notice: nil,
           member_error: member_error(reason)
         )}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case Members.remove(socket.assigns.current_scope, id) do
      :ok ->
        UserSession.disconnect(id)

        if id == socket.assigns.current_user.id,
          do: {:noreply, redirect(socket, to: ~p"/")},
          else: {:noreply, assign_members(socket)}

      {:error, _} ->
        {:noreply, assign_members(socket)}
    end
  end

  def handle_event("cancel_pending", %{"id" => id}, socket) do
    :ok = Members.cancel_pending(socket.assigns.current_scope, String.to_integer(id))
    {:noreply, assign_members(socket)}
  end

  def handle_event("switch_household", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Members.switch(user, String.to_integer(id)) do
      :ok ->
        UserSession.disconnect(user.id)
        {:noreply, redirect(socket, to: ~p"/")}

      {:error, :not_member} ->
        {:noreply, assign_members(socket)}
    end
  end

  def handle_event("toggle_ai_sponsor", _params, socket) do
    %{current_scope: scope, current_user: user, sponsoring: sponsoring} = socket.assigns
    _ = Household.set_ai_sponsor(scope, user, !sponsoring)
    {:noreply, assign_ai_sponsor(socket)}
  end

  def handle_event("rename_household", %{"name" => name}, socket) do
    case Household.rename(socket.assigns.current_scope, name) do
      {:ok, household} -> {:noreply, assign(socket, household: household)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  # An entry removed meanwhile by someone else is already gone, which is what was asked.
  def handle_event("forget_memory", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    _ = Memory.forget(scope, String.to_integer(id))
    {:noreply, assign(socket, memory: Memory.stores(scope))}
  end

  defp assign_members(socket) do
    scope = socket.assigns.current_scope
    assign(socket, users: Accounts.list_members(scope), pending: Members.list_pending(scope))
  end

  defp assign_ai_sponsor(socket) do
    sponsor = Household.ai_sponsor(socket.assigns.current_scope)

    assign(socket,
      ai_sponsor: sponsor,
      sponsoring: sponsor != nil and sponsor.id == socket.assigns.current_user.id
    )
  end

  defp member_error(:username_missing), do: gettext("Enter their Pocket ID username.")
  defp member_error(:already_member), do: gettext("They're already a member.")
  defp member_error(:already_added), do: gettext("They're already added.")

  defp format_usd(nil), do: "$0.00"
  defp format_usd(v), do: "$#{:erlang.float_to_binary(v / 1, decimals: 2)}"

  defp memory_part_label("profile"), do: gettext("Your household")
  defp memory_part_label("notes"), do: gettext("Notes")

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
                <button
                  :if={length(@users) > 1}
                  type="button"
                  phx-click="remove_member"
                  phx-value-id={user.id}
                  class="text-[color:var(--danger)] hover:underline"
                  style="font-size: var(--t-meta);"
                >
                  {if user.id == @current_user.id, do: gettext("Leave"), else: gettext("Remove")}
                </button>
              </div>
              <div :for={pending <- @pending} class="flex items-center gap-3">
                <div class="flex-1 min-w-0">
                  <p class="font-medium text-[var(--text)] truncate" style="font-size: var(--t-body);">
                    {pending.username}
                  </p>
                  <p class="text-[color:var(--muted)] truncate" style="font-size: var(--t-meta);">
                    {gettext("Joins at their first sign-in")}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="cancel_pending"
                  phx-value-id={pending.id}
                  class="text-[color:var(--danger)] hover:underline"
                  style="font-size: var(--t-meta);"
                >
                  {gettext("Remove")}
                </button>
              </div>
            </div>

            <form phx-submit="add_member" class="mt-4 flex items-center gap-2">
              <input
                type="text"
                name="username"
                value={@member_username}
                placeholder={gettext("Pocket ID username")}
                aria-label={gettext("Pocket ID username")}
                autocomplete="off"
                required
                class="flex-1 min-w-0 rounded-lg border border-[color:var(--hairline)] bg-[color:var(--surface)] px-3 py-2"
                style="font-size: var(--t-body);"
              />
              <.button type="submit" variant={:primary}>
                <.icon name="hero-plus" class="size-4" />{gettext("Add")}
              </.button>
            </form>
            <p
              :if={@member_notice}
              class="mt-1 text-[color:var(--muted)]"
              style="font-size: var(--t-meta);"
            >
              {@member_notice}
            </p>
            <p
              :if={@member_error}
              class="mt-1 text-[color:var(--danger)]"
              style="font-size: var(--t-meta);"
            >
              {@member_error}
            </p>

            <.link
              href={~p"/logout"}
              method="delete"
              class="mt-4 inline-block text-[color:var(--accent)] hover:underline"
              style="font-size: var(--t-meta);"
            >
              {gettext("Sign out")}
            </.link>
          </section>

          <%!-- Households: a switcher for someone in two or more --%>
          <section
            :if={length(@households) >= 2}
            class="px-6 pt-5 pb-5 border-t border-[color:var(--hairline)]"
          >
            <h2
              class="uppercase tracking-wider text-[color:var(--subtle)] mb-3"
              style="font-size: var(--t-micro); font-weight: 600;"
            >
              {gettext("Your households")}
            </h2>
            <div class="flex flex-col gap-3">
              <div :for={entry <- @households} class="flex items-center gap-3">
                <p
                  class="flex-1 min-w-0 font-medium text-[var(--text)] truncate"
                  style="font-size: var(--t-body);"
                >
                  {entry.household.name}
                </p>
                <span
                  :if={entry.active}
                  class="text-[color:var(--muted)]"
                  style="font-size: var(--t-meta);"
                >
                  {gettext("Current")}
                </span>
                <button
                  :if={!entry.active}
                  type="button"
                  phx-click="switch_household"
                  phx-value-id={entry.household.id}
                  class="font-medium text-[color:var(--accent)] hover:underline"
                  style="font-size: var(--t-meta);"
                >
                  {gettext("Switch")}
                </button>
              </div>
            </div>
          </section>

          <%!-- Household --%>
          <section class="px-6 pt-5 pb-5 border-t border-[color:var(--hairline)]">
            <h2
              class="uppercase tracking-wider text-[color:var(--subtle)] mb-3"
              style="font-size: var(--t-micro); font-weight: 600;"
            >
              {gettext("Household")}
            </h2>
            <form phx-submit="rename_household" class="mb-4 flex items-center gap-2">
              <input
                type="text"
                name="name"
                value={@household.name}
                aria-label={gettext("Household name")}
                required
                maxlength="100"
                class="flex-1 min-w-0 rounded-lg border border-[color:var(--hairline)] bg-[color:var(--surface)] px-3 py-2"
                style="font-size: var(--t-body);"
              />
              <.button type="submit" variant={:secondary}>{gettext("Rename")}</.button>
            </form>
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
            <%= if Enum.all?(@memory, &(&1.entries == [])) do %>
              <p class="text-sm text-zinc-500">
                {gettext("No memories yet. Tore learns as you cook.")}
              </p>
            <% else %>
              <div :for={part <- @memory} class="mb-4 last:mb-0">
                <div class="flex items-baseline justify-between mb-2">
                  <h3 class="text-sm font-medium">{memory_part_label(part.store)}</h3>
                  <span class="text-xs text-zinc-500">
                    {gettext("%{percent}% full", percent: part.percent)}
                  </span>
                </div>
                <ul class="space-y-2">
                  <li
                    :for={entry <- part.entries}
                    class="flex items-start justify-between gap-3 rounded-lg border border-zinc-200 p-3"
                  >
                    <p class="flex-1 text-sm">{entry.text}</p>
                    <button
                      phx-click="forget_memory"
                      phx-value-id={entry.id}
                      class="text-xs text-red-500 hover:text-red-700 shrink-0 mt-0.5"
                    >
                      {gettext("Forget")}
                    </button>
                  </li>
                </ul>
              </div>
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
            <div :if={@current_user.ai_enabled} class="mb-4 flex items-center justify-between gap-3">
              <p class="flex-1 min-w-0 text-[var(--text)]" style="font-size: var(--t-body);">
                {gettext("Use my credits for this household")}
              </p>
              <button
                type="button"
                role="switch"
                aria-checked={to_string(@sponsoring)}
                phx-click="toggle_ai_sponsor"
                class={[
                  "font-medium hover:underline",
                  if(@sponsoring,
                    do: "text-[color:var(--accent)]",
                    else: "text-[color:var(--muted)]"
                  )
                ]}
                style="font-size: var(--t-meta);"
              >
                {if @sponsoring,
                  do: gettext("On"),
                  else: gettext("Off")}
              </button>
            </div>
            <p
              :if={@ai_sponsor && @ai_sponsor.id != @current_user.id}
              class="mb-4 text-[color:var(--muted)]"
              style="font-size: var(--t-meta);"
            >
              {gettext("AI uses %{name}'s credits.", name: @ai_sponsor.name)}
            </p>
            <p
              :if={!@ai_sponsor && !@current_user.ai_enabled}
              class="mb-4 text-[color:var(--muted)]"
              style="font-size: var(--t-meta);"
            >
              {gettext("AI is off for this household.")}
            </p>
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
