defmodule ToreWeb.SettingsLive do
  use ToreWeb, :live_view

  alias Tore.Household.Memory
  alias Tore.{Accounts, Costs, Household, Members}
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
       prefs: Household.get_preferences(scope)
     )}
  end

  @dietary_restrictions ~w(vegetarian vegan gluten_free lactose_free low_carb high_protein nut_free)
  @allergies ~w(nuts shellfish gluten lactose eggs)

  def handle_event("toggle_restriction", %{"item" => value}, socket),
    do: toggle_preference(socket, :dietary_restrictions, value)

  def handle_event("toggle_allergy", %{"item" => value}, socket),
    do: toggle_preference(socket, :allergies, value)

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

  defp feature_label("canonicalise_pantry"), do: gettext("Pantry item matching")
  defp feature_label("generate_prep_guide"), do: gettext("Prep guide")
  defp feature_label("home_pick"), do: gettext("Home screen pick")
  defp feature_label("pi_chat"), do: gettext("Chat")
  defp feature_label("pi_finish_recipe"), do: gettext("Recipe steps and pictures")
  defp feature_label("pi_find_recipes"), do: gettext("Recipe search on the web")
  defp feature_label("pi_plan_week"), do: gettext("Planning")
  defp feature_label("pi_weekly_reflection"), do: gettext("Memory review")
  defp feature_label("suggest_recipe"), do: gettext("Recipe suggestions")
  defp feature_label("suggest_substitution"), do: gettext("Substitution suggestions")
  defp feature_label(f), do: f

  defp toggle_preference(socket, field, value) do
    current = Map.get(socket.assigns.prefs, field) || []
    updated = if value in current, do: List.delete(current, value), else: current ++ [value]

    case Household.update_preferences(socket.assigns.current_scope, %{field => updated}) do
      {:ok, prefs} -> {:noreply, assign(socket, prefs: prefs)}
      {:error, _} -> {:noreply, socket}
    end
  end

  defp preference_label("vegetarian"), do: gettext("Vegetarian")
  defp preference_label("vegan"), do: gettext("Vegan")
  defp preference_label("gluten_free"), do: gettext("Gluten-free")
  defp preference_label("lactose_free"), do: gettext("Lactose-free")
  defp preference_label("low_carb"), do: gettext("Low carb")
  defp preference_label("high_protein"), do: gettext("High protein")
  defp preference_label("nut_free"), do: gettext("Nut-free")
  defp preference_label("nuts"), do: gettext("Nuts")
  defp preference_label("shellfish"), do: gettext("Shellfish")
  defp preference_label("gluten"), do: gettext("Gluten")
  defp preference_label("lactose"), do: gettext("Lactose")
  defp preference_label("eggs"), do: gettext("Eggs")

  attr :items, :list, required: true
  attr :chosen, :list, required: true
  attr :event, :string, required: true

  defp preference_chips(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <button
        :for={item <- @items}
        type="button"
        phx-click={@event}
        phx-value-item={item}
        aria-pressed={to_string(item in (@chosen || []))}
        class={[
          "press h-9 rounded-full px-3.5 text-[14px] font-semibold",
          item in (@chosen || []) && "bg-[var(--text)] text-[color:var(--bg)]",
          item not in (@chosen || []) &&
            "bg-[var(--sunken)] text-[color:var(--muted)] hover:text-[color:var(--text)]"
        ]}
      >
        {preference_label(item)}
      </button>
    </div>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, dietary_restrictions: @dietary_restrictions, allergies: @allergies)

    ~H"""
    <Layouts.app
      flash={@flash}
      socket={@socket}
      current_user={@current_user}
    >
      <.page max_width={:md}>
        <header class="flex items-center gap-3 pt-2">
          <.link
            navigate={~p"/today"}
            aria-label={gettext("Back")}
            class="press -ml-1 flex size-11 shrink-0 items-center justify-center rounded-full bg-[var(--sunken)] text-[color:var(--text)] hover:bg-[var(--border)]"
          >
            <.icon name="ph-caret-left" class="size-5" />
          </.link>
        </header>
        <h1 class="t-display mt-5 mb-6">{gettext("Settings")}</h1>

        <div class="space-y-3">
          <%!-- Members --%>
          <section id="members" class="reveal rounded-[var(--r-xl)] bg-[var(--surface)] px-5 py-5">
            <h2 class="section-label mb-3">
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
                class="flex-1 min-w-0 rounded-[var(--r-md)] border border-[color:var(--hairline)] bg-[color:var(--surface)] px-3 py-2"
                style="font-size: var(--t-body);"
              />
              <.button type="submit" variant={:secondary}>{gettext("Add")}</.button>
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
              class="press mt-4 inline-flex h-10 items-center gap-2 font-semibold text-[color:var(--muted)] hover:text-[color:var(--text)]"
              style="font-size: 15px;"
            >
              <.icon name="ph-sign-out" class="size-4" />
              {gettext("Sign out")}
            </.link>
          </section>

          <%!-- Households: a switcher for someone in two or more --%>
          <section
            :if={length(@households) >= 2}
            class="reveal rounded-[var(--r-xl)] bg-[var(--surface)] px-5 py-5"
          >
            <h2 class="section-label mb-3">
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

          <%!-- Diet and allergies: every plan is checked against these --%>
          <section
            id="diet"
            class="reveal rounded-[var(--r-xl)] bg-[var(--surface)] px-5 py-5"
          >
            <h2 class="section-label mb-1">{gettext("Diet and allergies")}</h2>
            <p class="mb-3 text-[color:var(--muted)]" style="font-size: var(--t-meta);">
              {gettext("Tore checks every plan against these. Tastes it learns as you plan.")}
            </p>
            <p class="mb-2 text-[color:var(--text)]" style="font-size: var(--t-meta);">
              {gettext("We eat")}
            </p>
            <.preference_chips
              items={@dietary_restrictions}
              chosen={@prefs.dietary_restrictions}
              event="toggle_restriction"
            />
            <p class="mt-4 mb-2 text-[color:var(--text)]" style="font-size: var(--t-meta);">
              {gettext("Never include")}
            </p>
            <.preference_chips items={@allergies} chosen={@prefs.allergies} event="toggle_allergy" />
          </section>

          <%!-- Household --%>
          <section class="reveal rounded-[var(--r-xl)] bg-[var(--surface)] px-5 py-5">
            <h2 class="section-label mb-3">
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
                class="flex-1 min-w-0 rounded-[var(--r-md)] border border-[color:var(--hairline)] bg-[color:var(--surface)] px-3 py-2"
                style="font-size: var(--t-body);"
              />
              <button
                type="submit"
                class="h-11 shrink-0 px-2 text-[13px] font-semibold text-[color:var(--accent)] hover:underline"
              >
                {gettext("Rename")}
              </button>
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
          <section class="reveal rounded-[var(--r-xl)] bg-[var(--surface)] px-5 py-5">
            <h2 class="section-label mb-3">
              {gettext("Things Tore has learned")}
            </h2>
            <%= if Enum.all?(@memory, &(&1.entries == [])) do %>
              <p class="text-sm text-[color:var(--muted)]">
                {gettext("No memories yet. Tore learns as you cook.")}
              </p>
            <% else %>
              <div :for={part <- @memory} class="mb-4 last:mb-0">
                <div class="flex items-baseline justify-between mb-2">
                  <h3 class="text-sm font-medium">{memory_part_label(part.store)}</h3>
                  <span class="text-xs text-[color:var(--muted)]">
                    {gettext("%{percent}% full", percent: part.percent)}
                  </span>
                </div>
                <ul class="space-y-2">
                  <li
                    :for={entry <- part.entries}
                    class="flex items-start justify-between gap-3 rounded-[var(--r-md)] border border-[color:var(--border)] bg-[var(--surface)] p-3"
                  >
                    <p class="flex-1 text-sm">{entry.text}</p>
                    <button
                      phx-click="forget_memory"
                      phx-value-id={entry.id}
                      class="shrink-0 text-[13px] font-medium text-[color:var(--muted)] hover:text-[color:var(--danger)] hover:underline"
                    >
                      {gettext("Forget")}
                    </button>
                  </li>
                </ul>
              </div>
            <% end %>
          </section>

          <%!-- AI usage --%>
          <section class="reveal rounded-[var(--r-xl)] bg-[var(--surface)] px-5 py-5">
            <h2 class="section-label mb-3">
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
        </div>
      </.page>
    </Layouts.app>
    """
  end
end
