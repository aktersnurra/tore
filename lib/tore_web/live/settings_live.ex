defmodule ToreWeb.SettingsLive do
  @moduledoc """
  Settings as one grouped list, each row with what it's set to; a row opens its setting on a page
  of its own (`/settings/<section>`), patched in so going back is instant. The look (system, light
  or dark) is chosen on the list itself: it's the device's, kept in the browser.
  """
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
       name_saved?: false,
       member_added: nil,
       member_error: nil,
       households: Members.list_households(socket.assigns.current_user),
       ai: ai,
       memory: Memory.stores(socket.assigns.current_scope),
       household: Household.get!(socket.assigns.current_scope),
       prefs: Household.get_preferences(scope)
     )}
  end

  @sections ~w(name members food memory ai households)

  def handle_params(params, _uri, socket) do
    section = if params["section"] in @sections, do: params["section"]

    # A page opened again starts as it is, not with the last save's flash or note.
    {:noreply,
     assign(socket,
       section: section,
       name_saved?: false,
       member_added: nil,
       member_error: nil
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
        # The new row flashes green; it already says whether they've joined or join later.
        added =
          case result do
            {:pending, username} ->
              {:pending, username}

            {:moved, user} ->
              # Their empty household is gone, so their open pages move here.
              UserSession.disconnect(user.id)
              {:user, user.id}

            {:added, user} ->
              {:user, user.id}
          end

        {:noreply,
         socket
         |> assign_members()
         |> assign(member_username: "", member_added: added, member_error: nil)}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           member_username: username,
           member_added: nil,
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

  # Typing again lets the next save flash anew.
  def handle_event("edit_name", _params, socket),
    do: {:noreply, assign(socket, name_saved?: false)}

  def handle_event("rename_household", %{"name" => name}, socket) do
    case Household.rename(socket.assigns.current_scope, name) do
      {:ok, household} ->
        {:noreply, assign(socket, household: household, name_saved?: true)}

      {:error, _changeset} ->
        {:noreply, socket}
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

  defp section_title("name"), do: gettext("Name")
  defp section_title("members"), do: gettext("Members")
  defp section_title("food"), do: gettext("Diet and allergies")
  defp section_title("memory"), do: gettext("Things Tore has learned")
  defp section_title("ai"), do: gettext("AI usage")
  defp section_title("households"), do: gettext("Your households")

  # What a row shows it's set to.
  defp food_value(prefs) do
    case (prefs.dietary_restrictions || []) ++ (prefs.allergies || []) do
      [] -> gettext("Anything")
      chosen -> Enum.map_join(chosen, " · ", &preference_label/1)
    end
  end

  defp memory_value(memory) do
    case Enum.sum_by(memory, &length(&1.entries)) do
      0 -> gettext("None yet")
      n -> ngettext("%{count} thing", "%{count} things", n)
    end
  end

  defp members_value(users, pending),
    do: ngettext("%{count} person", "%{count} people", length(users) + length(pending))

  defp memory_part_label("profile"), do: gettext("Your household")
  defp memory_part_label("notes"), do: gettext("Notes")

  defp feature_label("deal_picks"), do: gettext("Sorting offers")
  defp feature_label("pi_learn"), do: gettext("Pantry item matching")
  defp feature_label("pi_prep_guide"), do: gettext("Prep guide")
  defp feature_label("pi_home_pick"), do: gettext("Home screen pick")
  defp feature_label("pi_chat"), do: gettext("Chat")
  defp feature_label("pi_finish_recipe"), do: gettext("Recipe steps and pictures")
  defp feature_label("recipe_picture"), do: gettext("Drawing recipe pictures")
  defp feature_label("pi_find_recipes"), do: gettext("Recipe search on the web")
  defp feature_label("pi_plan_week"), do: gettext("Planning")
  defp feature_label("pi_weekly_reflection"), do: gettext("Memory review")
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
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <.page max_width={:md}>
        <%!-- The list --%>
        <div :if={!@section} id="settings-list" class="settle">
          <h1 class="t-display mt-4 mb-6">{gettext("Settings")}</h1>

          <.group label={gettext("Household")}>
            <.setting section="name" label={gettext("Name")} value={@household.name} />
            <.setting
              section="members"
              label={gettext("Members")}
              value={members_value(@users, @pending)}
            />
            <div class="flex min-h-12 items-center justify-between gap-3 py-2">
              <span>{gettext("Language")}</span>
              <span class="text-[color:var(--muted)]">
                {Household.locale_label(@household.locale)}
              </span>
            </div>
            <:footer>
              {gettext("Used for reading receipts, recipes and grocery labels. Chosen once.")}
            </:footer>
          </.group>

          <.group label={gettext("Food")}>
            <.setting section="food" label={gettext("Diet and allergies")} value={food_value(@prefs)} />
            <:footer>
              {gettext("Tore checks every plan against these. Tastes it learns as you plan.")}
            </:footer>
          </.group>

          <.group label="Tore">
            <.setting
              section="memory"
              label={gettext("Things Tore has learned")}
              value={memory_value(@memory)}
            />
            <.setting
              section="ai"
              label={gettext("AI usage")}
              value={gettext("%{amount} this month", amount: format_usd(@ai.this_month))}
            />
          </.group>

          <.group label={gettext("This device")}>
            <div class="flex min-h-12 items-center justify-between gap-3 py-2">
              <span>{gettext("Look")}</span>
              <.look />
            </div>
          </.group>

          <.group label={gettext("Account")}>
            <.setting
              :if={length(@households) >= 2}
              section="households"
              label={gettext("Your households")}
              value={@household.name}
            />
            <.link
              href={~p"/logout"}
              method="delete"
              class="press -mx-4 flex min-h-12 items-center gap-2 px-4 py-2 text-[color:var(--danger)] row-hover"
            >
              <.icon name="ph-sign-out" class="size-[18px]" />
              {gettext("Sign out")}
            </.link>
          </.group>
        </div>

        <%!-- One setting, on its own page --%>
        <div :if={@section} id={"settings-#{@section}"} class="settle">
          <header class="flex items-center gap-2 pt-2">
            <.link
              patch={~p"/settings"}
              data-role="settings-back"
              aria-label={gettext("Settings")}
              class="press -ml-2 flex h-11 items-center gap-0.5 rounded-full pr-3 pl-1 text-[color:var(--muted)] hover:text-[color:var(--text)]"
            >
              <.icon name="ph-caret-left" class="size-5" />
              <span class="text-[15px]">{gettext("Settings")}</span>
            </.link>
          </header>
          <h1 class="t-display mt-3 mb-6">{section_title(@section)}</h1>

          <%!-- A plain field: Enter saves it, and it flashes green when saved. --%>
          <form :if={@section == "name"} phx-submit="rename_household" phx-change="edit_name">
            <.field
              id="household-name"
              name="name"
              value={@household.name}
              saved={@name_saved?}
              aria-label={gettext("Household name")}
              required
              maxlength="100"
              autocomplete="off"
              enterkeyhint="done"
              input_class="font-medium"
            />
          </form>

          <div :if={@section == "members"} class="menu-lines py-4">
            <div class="flex flex-col gap-3">
              <div
                :for={user <- @users}
                data-role="member"
                class={["member-row", @member_added == {:user, user.id} && "row-added"]}
              >
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
                <.icon_button
                  :if={length(@users) > 1}
                  icon={if user.id == @current_user.id, do: "ph-sign-out", else: "ph-trash"}
                  label={
                    if user.id == @current_user.id,
                      do: gettext("Leave"),
                      else: gettext("Remove %{name}", name: user.name)
                  }
                  variant={:danger}
                  phx-click="remove_member"
                  phx-value-id={user.id}
                />
              </div>
              <div
                :for={pending <- @pending}
                data-role="member"
                class={["member-row", @member_added == {:pending, pending.username} && "row-added"]}
              >
                <div class="flex-1 min-w-0">
                  <p class="font-medium text-[var(--text)] truncate" style="font-size: var(--t-body);">
                    {pending.username}
                  </p>
                  <p class="text-[color:var(--muted)] truncate" style="font-size: var(--t-meta);">
                    {gettext("Joins at their first sign-in")}
                  </p>
                </div>
                <.icon_button
                  icon="ph-trash"
                  label={gettext("Remove %{name}", name: pending.username)}
                  variant={:danger}
                  phx-click="cancel_pending"
                  phx-value-id={pending.id}
                />
              </div>
            </div>

            <form phx-submit="add_member" class="mt-4">
              <.field
                id="member-username"
                name="username"
                value={@member_username}
                placeholder={gettext("Pocket ID username")}
                aria-label={gettext("Pocket ID username")}
                autocomplete="off"
                autocapitalize="off"
                required
                errors={List.wrap(@member_error)}
                enterkeyhint="done"
              />
              <button type="submit" class="sr-only">{gettext("Add")}</button>
            </form>
          </div>

          <div :if={@section == "food"} class="space-y-6">
            <div>
              <p class="section-label mb-2">{gettext("We eat")}</p>
              <.preference_chips
                items={@dietary_restrictions}
                chosen={@prefs.dietary_restrictions}
                event="toggle_restriction"
              />
            </div>
            <div>
              <p class="section-label mb-2">{gettext("Never include")}</p>
              <.preference_chips items={@allergies} chosen={@prefs.allergies} event="toggle_allergy" />
            </div>
            <p class="text-[13px] text-[color:var(--muted)]">
              {gettext("Tore checks every plan against these. Tastes it learns as you plan.")}
            </p>
          </div>

          <%!-- Each part is one card of rows, as the other settings are; a part with nothing in
             it isn't shown. --%>
          <div :if={@section == "memory"} class="space-y-6">
            <p
              :if={Enum.all?(@memory, &(&1.entries == []))}
              class="menu-lines py-4 text-[color:var(--muted)]"
              style="font-size: var(--t-body);"
            >
              {gettext("No memories yet. Tore learns as you cook.")}
            </p>
            <section :for={part <- @memory} :if={part.entries != []}>
              <div class="mb-2 flex items-baseline justify-between px-1">
                <h3 class="section-label">{memory_part_label(part.store)}</h3>
                <span class="num text-[color:var(--muted)]" style="font-size: var(--t-meta);">
                  {gettext("%{percent}% full", percent: part.percent)}
                </span>
              </div>
              <ul class="menu-lines">
                <li :for={entry <- part.entries} class="flex items-start gap-2 py-1">
                  <p class="flex-1 py-2.5 text-[color:var(--text)]" style="font-size: var(--t-body);">
                    {entry.text}
                  </p>
                  <.icon_button
                    icon="ph-trash"
                    label={gettext("Forget")}
                    variant={:danger}
                    phx-click="forget_memory"
                    phx-value-id={entry.id}
                  />
                </li>
              </ul>
            </section>
          </div>

          <div :if={@section == "ai"} class="menu-lines py-4">
            <div :if={@current_user.ai_enabled} class="mb-4 flex items-center justify-between gap-3">
              <p class="flex-1 min-w-0 text-[var(--text)]" style="font-size: var(--t-body);">
                {gettext("Use my credits for this household")}
              </p>
              <button
                type="button"
                role="switch"
                aria-checked={to_string(@sponsoring)}
                aria-label={gettext("Use my credits for this household")}
                phx-click="toggle_ai_sponsor"
                class="switch shrink-0"
              >
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
          </div>

          <div :if={@section == "households"} class="menu-lines py-4">
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
          </div>
        </div>
      </.page>
    </Layouts.app>
    """
  end

  # A group of rows under a quiet label, with a line of explanation under it when it needs one.
  attr :label, :string, required: true
  slot :inner_block, required: true
  slot :footer

  defp group(assigns) do
    ~H"""
    <section class="mb-7">
      <h2 class="section-label mb-2 px-1">{@label}</h2>
      <div class="menu-lines overflow-hidden text-[16px] text-[color:var(--text)]">
        {render_slot(@inner_block)}
      </div>
      <p :for={footer <- @footer} class="mt-2 px-1 text-[13px] leading-snug text-[color:var(--muted)]">
        {render_slot(footer)}
      </p>
    </section>
    """
  end

  # A setting: its name, what it's set to, and a way into its page.
  attr :section, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :rest, :global

  defp setting(assigns) do
    ~H"""
    <.link
      patch={~p"/settings/#{@section}"}
      data-role="setting"
      class="press row-hover -mx-4 flex min-h-12 items-center gap-3 px-4 py-2"
      {@rest}
    >
      <span class="shrink-0">{@label}</span>
      <span class="min-w-0 flex-1 truncate text-right text-[color:var(--muted)]">{@value}</span>
      <.icon name="ph-caret-right" class="size-4 shrink-0 text-[color:var(--subtle)]" />
    </.link>
    """
  end

  # System, light or dark: the browser keeps it (see the root layout), so which one is on is shown
  # from the page's own data-theme rather than from the server.
  defp look(assigns) do
    ~H"""
    <div
      data-role="look"
      role="group"
      aria-label={gettext("Look")}
      class="flex rounded-full bg-[var(--sunken)] p-0.5 text-[14px] font-semibold"
    >
      <button
        :for={
          {theme, label, on} <- [
            {"system", gettext("System"),
             "[html:not([data-theme])_&]:bg-[var(--surface)] [html:not([data-theme])_&]:text-[color:var(--text)] [html:not([data-theme])_&]:shadow-sm"},
            {"light", gettext("Light"),
             "[[data-theme=light]_&]:bg-[var(--surface)] [[data-theme=light]_&]:text-[color:var(--text)] [[data-theme=light]_&]:shadow-sm"},
            {"dark", gettext("Dark"),
             "[[data-theme=dark]_&]:bg-[var(--surface)] [[data-theme=dark]_&]:text-[color:var(--text)] [[data-theme=dark]_&]:shadow-sm"}
          ]
        }
        type="button"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        class={[
          "press h-8 rounded-full px-3 text-[color:var(--muted)] transition-colors duration-150",
          on
        ]}
      >
        {label}
      </button>
    </div>
    """
  end
end
