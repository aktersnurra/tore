defmodule ToreWeb.CookingLive do
  use ToreWeb, :live_view

  alias Tore.Household

  @dietary_restrictions ~w(vegetarian vegan gluten_free lactose_free low_carb high_protein nut_free)
  @allergies ~w(nuts shellfish gluten lactose eggs)
  @cooking_style ~w(batch_cooking quick_weekdays budget_focused kid_friendly swedish_comfort more_vegetables fewer_dishes)
  @cuisines ~w(swedish italian japanese korean mexican middle_eastern indian mediterranean)

  def mount(_params, _session, socket) do
    prefs = Household.get_preferences(socket.assigns.current_scope)

    {:ok,
     assign(socket,
       prefs: prefs,
       dislike_input: "",
       saved: false
     )}
  end

  def handle_event("toggle_restriction", %{"item" => value}, socket) do
    prefs = socket.assigns.prefs
    current = prefs.dietary_restrictions || []
    updated = toggle_list(current, value)
    save_and_assign(socket, %{dietary_restrictions: updated})
  end

  def handle_event("toggle_allergy", %{"item" => value}, socket) do
    prefs = socket.assigns.prefs
    current = prefs.allergies || []
    updated = toggle_list(current, value)
    save_and_assign(socket, %{allergies: updated})
  end

  def handle_event("toggle_style", %{"item" => value}, socket) do
    prefs = socket.assigns.prefs
    current = prefs.cooking_style || []
    updated = toggle_list(current, value)
    save_and_assign(socket, %{cooking_style: updated})
  end

  def handle_event("set_cuisine", %{"cuisine" => cuisine, "rating" => rating}, socket) do
    prefs = socket.assigns.prefs
    current = prefs.cuisine_preferences || %{}

    updated =
      if rating == "neutral",
        do: Map.delete(current, cuisine),
        else: Map.put(current, cuisine, rating)

    save_and_assign(socket, %{cuisine_preferences: updated})
  end

  def handle_event("add_dislike", %{"dislike" => value}, socket) do
    value = String.trim(value)

    if value == "" do
      {:noreply, socket}
    else
      prefs = socket.assigns.prefs
      current = prefs.dislikes || []
      updated = if value in current, do: current, else: current ++ [value]
      save_and_assign(socket, %{dislikes: updated}, dislike_input: "")
    end
  end

  def handle_event("remove_dislike", %{"item" => value}, socket) do
    prefs = socket.assigns.prefs
    updated = List.delete(prefs.dislikes || [], value)
    save_and_assign(socket, %{dislikes: updated})
  end

  def handle_event("inc_portions", %{"field" => field}, socket) do
    prefs = socket.assigns.prefs
    key = String.to_existing_atom(field)
    current = Map.get(prefs, key) || 1
    save_and_assign(socket, %{key => min(current + 1, 20)})
  end

  def handle_event("dec_portions", %{"field" => field}, socket) do
    prefs = socket.assigns.prefs
    key = String.to_existing_atom(field)
    current = Map.get(prefs, key) || 1
    min_val = if field == "default_leftover_portions", do: 0, else: 1
    save_and_assign(socket, %{key => max(current - 1, min_val)})
  end

  def handle_event("toggle_lunches", _params, socket) do
    prefs = socket.assigns.prefs
    save_and_assign(socket, %{include_lunches: !prefs.include_lunches})
  end

  def handle_event("set_planning_days", %{"days" => days}, socket) do
    save_and_assign(socket, %{planning_days: String.to_integer(days)})
  end

  defp save_and_assign(socket, attrs, extra \\ []) do
    prefs = socket.assigns.prefs
    full_attrs = Map.merge(prefs_to_map(prefs), attrs)

    case Household.update_preferences(socket.assigns.current_scope, full_attrs) do
      {:ok, updated} ->
        assigns = [prefs: updated, saved: true] ++ extra
        {:noreply, assign(socket, assigns)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp toggle_list(list, value) do
    if value in list, do: List.delete(list, value), else: list ++ [value]
  end

  defp prefs_to_map(prefs) do
    %{
      dietary_restrictions: prefs.dietary_restrictions || [],
      allergies: prefs.allergies || [],
      dislikes: prefs.dislikes || [],
      cooking_style: prefs.cooking_style || [],
      cuisine_preferences: prefs.cuisine_preferences || %{},
      default_portions: prefs.default_portions,
      default_leftover_portions: prefs.default_leftover_portions,
      include_lunches: prefs.include_lunches,
      planning_days: prefs.planning_days
    }
  end

  defp active_chip?(list, value), do: value in (list || [])

  defp label_for("vegetarian"), do: gettext("Vegetarian")
  defp label_for("vegan"), do: gettext("Vegan")
  defp label_for("gluten_free"), do: gettext("Gluten-free")
  defp label_for("lactose_free"), do: gettext("Lactose-free")
  defp label_for("low_carb"), do: gettext("Low carb")
  defp label_for("high_protein"), do: gettext("High protein")
  defp label_for("nut_free"), do: gettext("Nut-free")
  defp label_for("nuts"), do: gettext("Nuts")
  defp label_for("shellfish"), do: gettext("Shellfish")
  defp label_for("gluten"), do: gettext("Gluten")
  defp label_for("lactose"), do: gettext("Lactose")
  defp label_for("eggs"), do: gettext("Eggs")
  defp label_for("batch_cooking"), do: gettext("Batch cooking")
  defp label_for("quick_weekdays"), do: gettext("Quick weekdays")
  defp label_for("budget_focused"), do: gettext("Budget-focused")
  defp label_for("kid_friendly"), do: gettext("Kid-friendly")
  defp label_for("swedish_comfort"), do: gettext("Swedish comfort food")
  defp label_for("more_vegetables"), do: gettext("More vegetables")
  defp label_for("fewer_dishes"), do: gettext("Fewer dishes")
  defp label_for("swedish"), do: gettext("Swedish")
  defp label_for("italian"), do: gettext("Italian")
  defp label_for("japanese"), do: gettext("Japanese")
  defp label_for("korean"), do: gettext("Korean")
  defp label_for("mexican"), do: gettext("Mexican")
  defp label_for("middle_eastern"), do: gettext("Middle Eastern")
  defp label_for("indian"), do: gettext("Indian")
  defp label_for("mediterranean"), do: gettext("Mediterranean")
  defp label_for(v), do: v

  def render(assigns) do
    assigns =
      assign(assigns,
        dietary_restrictions: @dietary_restrictions,
        allergies: @allergies,
        cooking_style: @cooking_style,
        cuisines: @cuisines
      )

    ~H"""
    <Layouts.app flash={@flash} current_path={assigns[:current_path] || "/cooking"}>
      <.page max_width={:md}>
        <.card padded={false}>
          <header class="px-6 pt-6 pb-4">
            <h1 class="font-semibold text-[var(--text)]" style="font-size: var(--t-h1);">
              {gettext("Household kitchen")}
            </h1>
            <p class="text-[color:var(--muted)] mt-1" style="font-size: var(--t-meta);">
              {gettext("Used when planning dinners, leftovers, and grocery lists.")}
            </p>
          </header>

          <%!-- We eat --%>
          <section class="grid grid-cols-[1fr_2fr] gap-x-6 px-6 py-5 border-t border-[color:var(--hairline)]">
            <div>
              <p class="font-medium text-[var(--text)]" style="font-size: var(--t-body);">
                {gettext("We eat")}
              </p>
              <p class="text-[color:var(--muted)] mt-0.5" style="font-size: var(--t-meta);">
                {gettext("Tell us what we should cook around.")}
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                :for={r <- @dietary_restrictions}
                type="button"
                phx-click="toggle_restriction"
                phx-value-item={r}
                class={[
                  "px-3 py-1.5 rounded-full border text-sm font-medium transition-colors",
                  active_chip?(@prefs.dietary_restrictions, r) &&
                    "bg-[color:var(--accent)] border-[color:var(--accent)] text-white",
                  !active_chip?(@prefs.dietary_restrictions, r) &&
                    "bg-[color:var(--surface)] border-[color:var(--hairline)] text-[color:var(--muted)] hover:border-[color:var(--accent)] hover:text-[color:var(--accent)]"
                ]}
              >
                {label_for(r)}
              </button>
            </div>
          </section>

          <%!-- Never include --%>
          <section class="grid grid-cols-[1fr_2fr] gap-x-6 px-6 py-5 border-t border-[color:var(--hairline)]">
            <div>
              <p class="font-medium text-[var(--text)]" style="font-size: var(--t-body);">
                {gettext("Never include")}
              </p>
              <p class="text-[color:var(--muted)] mt-0.5" style="font-size: var(--t-meta);">
                {gettext("Allergies and hard avoids — never suggested.")}
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                :for={a <- @allergies}
                type="button"
                phx-click="toggle_allergy"
                phx-value-item={a}
                class={[
                  "px-3 py-1.5 rounded-full border text-sm font-medium transition-colors",
                  active_chip?(@prefs.allergies, a) &&
                    "bg-[color:var(--warn)] border-[color:var(--warn)] text-white",
                  !active_chip?(@prefs.allergies, a) &&
                    "bg-[color:var(--surface)] border-[color:var(--hairline)] text-[color:var(--muted)] hover:border-[color:var(--warn)] hover:text-[color:var(--warn)]"
                ]}
              >
                {label_for(a)}
              </button>
            </div>
          </section>

          <%!-- Our kitchen --%>
          <section class="grid grid-cols-[1fr_2fr] gap-x-6 px-6 py-5 border-t border-[color:var(--hairline)]">
            <div>
              <p class="font-medium text-[var(--text)]" style="font-size: var(--t-body);">
                {gettext("Our kitchen")}
              </p>
              <p class="text-[color:var(--muted)] mt-0.5" style="font-size: var(--t-meta);">
                {gettext("How we like to cook and what matters to us.")}
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                :for={s <- @cooking_style}
                type="button"
                phx-click="toggle_style"
                phx-value-item={s}
                class={[
                  "px-3 py-1.5 rounded-full border text-sm font-medium transition-colors",
                  active_chip?(@prefs.cooking_style, s) &&
                    "bg-[color:var(--accent)] border-[color:var(--accent)] text-white",
                  !active_chip?(@prefs.cooking_style, s) &&
                    "bg-[color:var(--surface)] border-[color:var(--hairline)] text-[color:var(--muted)] hover:border-[color:var(--accent)] hover:text-[color:var(--accent)]"
                ]}
              >
                {label_for(s)}
              </button>
            </div>
          </section>

          <%!-- Flavours we enjoy --%>
          <section class="grid grid-cols-[1fr_2fr] gap-x-6 px-6 py-5 border-t border-[color:var(--hairline)]">
            <div>
              <p class="font-medium text-[var(--text)]" style="font-size: var(--t-body);">
                {gettext("Flavours we enjoy")}
              </p>
              <p class="text-[color:var(--muted)] mt-0.5" style="font-size: var(--t-meta);">
                {gettext("Cuisines and styles we want more or less of.")}
              </p>
            </div>
            <div class="flex flex-col gap-2">
              <div :for={cuisine <- @cuisines} class="flex items-center justify-between gap-3">
                <span class="text-[var(--text)]" style="font-size: var(--t-body);">
                  {label_for(cuisine)}
                </span>
                <div class="flex items-center gap-1 shrink-0">
                  <button
                    type="button"
                    phx-click="set_cuisine"
                    phx-value-cuisine={cuisine}
                    phx-value-rating={
                      if Map.get(@prefs.cuisine_preferences || %{}, cuisine) == "less",
                        do: "neutral",
                        else: "less"
                    }
                    class={[
                      "size-8 rounded-full border flex items-center justify-center transition-colors",
                      Map.get(@prefs.cuisine_preferences || %{}, cuisine) == "less" &&
                        "bg-[color:var(--warn)] border-[color:var(--warn)] text-white",
                      Map.get(@prefs.cuisine_preferences || %{}, cuisine) != "less" &&
                        "bg-[color:var(--surface)] border-[color:var(--hairline)] text-[color:var(--muted)] hover:border-[color:var(--warn)] hover:text-[color:var(--warn)]"
                    ]}
                  >
                    <.icon name="hero-minus" class="size-3.5" />
                  </button>
                  <button
                    type="button"
                    phx-click="set_cuisine"
                    phx-value-cuisine={cuisine}
                    phx-value-rating={
                      if Map.get(@prefs.cuisine_preferences || %{}, cuisine) == "more",
                        do: "neutral",
                        else: "more"
                    }
                    class={[
                      "size-8 rounded-full border flex items-center justify-center transition-colors",
                      Map.get(@prefs.cuisine_preferences || %{}, cuisine) == "more" &&
                        "bg-[color:var(--accent)] border-[color:var(--accent)] text-white",
                      Map.get(@prefs.cuisine_preferences || %{}, cuisine) != "more" &&
                        "bg-[color:var(--surface)] border-[color:var(--hairline)] text-[color:var(--muted)] hover:border-[color:var(--accent)] hover:text-[color:var(--accent)]"
                    ]}
                  >
                    <.icon name="hero-plus" class="size-3.5" />
                  </button>
                </div>
              </div>
            </div>
          </section>

          <%!-- Avoid too often --%>
          <section class="grid grid-cols-[1fr_2fr] gap-x-6 px-6 py-5 border-t border-[color:var(--hairline)]">
            <div>
              <p class="font-medium text-[var(--text)]" style="font-size: var(--t-body);">
                {gettext("Avoid too often")}
              </p>
              <p class="text-[color:var(--muted)] mt-0.5" style="font-size: var(--t-meta);">
                {gettext("Soft dislikes — helps us keep it varied.")}
              </p>
            </div>
            <div>
              <div class="flex flex-wrap gap-2 mb-3">
                <button
                  :for={d <- @prefs.dislikes || []}
                  type="button"
                  phx-click="remove_dislike"
                  phx-value-item={d}
                  class="inline-flex items-center gap-1 px-3 py-1.5 rounded-full border bg-[color:var(--surface)] border-[color:var(--hairline)] text-[color:var(--text)] text-sm font-medium hover:border-[color:var(--danger)] hover:text-[color:var(--danger)] transition-colors"
                >
                  {d}<.icon name="hero-x-mark" class="size-3" />
                </button>
              </div>
              <form phx-submit="add_dislike" class="flex gap-2">
                <input
                  type="text"
                  name="dislike"
                  value={@dislike_input}
                  placeholder={gettext("e.g. coriander")}
                  class="flex-1 rounded-lg border border-[color:var(--hairline)] bg-[color:var(--surface)] px-3 py-1.5 text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)]"
                  style="font-size: var(--t-body);"
                />
                <.button type="submit" variant={:secondary}>{gettext("Add")}</.button>
              </form>
            </div>
          </section>

          <%!-- Our routine --%>
          <section class="grid grid-cols-[1fr_2fr] gap-x-6 px-6 py-5 border-t border-[color:var(--hairline)]">
            <div>
              <p class="font-medium text-[var(--text)]" style="font-size: var(--t-body);">
                {gettext("Our routine")}
              </p>
              <p class="text-[color:var(--muted)] mt-0.5" style="font-size: var(--t-meta);">
                {gettext("Portions and planning schedule.")}
              </p>
            </div>
            <div class="flex flex-col gap-4">
              <div class="flex items-center justify-between gap-3">
                <span class="text-[var(--text)]" style="font-size: var(--t-body);">
                  {gettext("Dinner portions")}
                </span>
                <div class="flex items-center gap-2 shrink-0">
                  <button
                    type="button"
                    phx-click="dec_portions"
                    phx-value-field="default_portions"
                    class="size-8 rounded-full border border-[color:var(--hairline)] bg-[color:var(--surface)] flex items-center justify-center text-[color:var(--muted)] hover:border-[color:var(--accent)] hover:text-[color:var(--accent)] transition-colors"
                  >
                    <.icon name="hero-minus" class="size-3.5" />
                  </button>
                  <span
                    class="w-6 text-center font-medium tabular-nums text-[var(--text)]"
                    style="font-size: var(--t-body);"
                  >
                    {@prefs.default_portions}
                  </span>
                  <button
                    type="button"
                    phx-click="inc_portions"
                    phx-value-field="default_portions"
                    class="size-8 rounded-full border border-[color:var(--hairline)] bg-[color:var(--surface)] flex items-center justify-center text-[color:var(--muted)] hover:border-[color:var(--accent)] hover:text-[color:var(--accent)] transition-colors"
                  >
                    <.icon name="hero-plus" class="size-3.5" />
                  </button>
                </div>
              </div>
              <div class="flex items-center justify-between gap-3">
                <span class="text-[var(--text)]" style="font-size: var(--t-body);">
                  {gettext("Leftovers (matlådor)")}
                </span>
                <div class="flex items-center gap-2 shrink-0">
                  <button
                    type="button"
                    phx-click="dec_portions"
                    phx-value-field="default_leftover_portions"
                    class="size-8 rounded-full border border-[color:var(--hairline)] bg-[color:var(--surface)] flex items-center justify-center text-[color:var(--muted)] hover:border-[color:var(--accent)] hover:text-[color:var(--accent)] transition-colors"
                  >
                    <.icon name="hero-minus" class="size-3.5" />
                  </button>
                  <span
                    class="w-6 text-center font-medium tabular-nums text-[var(--text)]"
                    style="font-size: var(--t-body);"
                  >
                    {@prefs.default_leftover_portions}
                  </span>
                  <button
                    type="button"
                    phx-click="inc_portions"
                    phx-value-field="default_leftover_portions"
                    class="size-8 rounded-full border border-[color:var(--hairline)] bg-[color:var(--surface)] flex items-center justify-center text-[color:var(--muted)] hover:border-[color:var(--accent)] hover:text-[color:var(--accent)] transition-colors"
                  >
                    <.icon name="hero-plus" class="size-3.5" />
                  </button>
                </div>
              </div>
              <div class="flex items-center justify-between gap-3">
                <span class="text-[var(--text)]" style="font-size: var(--t-body);">
                  {gettext("Include lunches")}
                </span>
                <button
                  type="button"
                  phx-click="toggle_lunches"
                  class={[
                    "relative inline-flex h-6 w-11 items-center rounded-full border-2 transition-colors shrink-0",
                    @prefs.include_lunches && "bg-[color:var(--accent)] border-[color:var(--accent)]",
                    !@prefs.include_lunches &&
                      "bg-[color:var(--hairline)] border-[color:var(--hairline)]"
                  ]}
                >
                  <span class={[
                    "inline-block h-4 w-4 rounded-full bg-white shadow transition-transform",
                    @prefs.include_lunches && "translate-x-5",
                    !@prefs.include_lunches && "translate-x-0.5"
                  ]} />
                </button>
              </div>
              <div class="flex items-center justify-between gap-3">
                <span class="text-[var(--text)]" style="font-size: var(--t-body);">
                  {gettext("Plan days")}
                </span>
                <div class="flex gap-1 shrink-0">
                  <button
                    type="button"
                    phx-click="set_planning_days"
                    phx-value-days="5"
                    class={[
                      "px-3 py-1 rounded-full border text-sm font-medium transition-colors",
                      @prefs.planning_days == 5 &&
                        "bg-[color:var(--accent)] border-[color:var(--accent)] text-white",
                      @prefs.planning_days != 5 &&
                        "bg-[color:var(--surface)] border-[color:var(--hairline)] text-[color:var(--muted)] hover:border-[color:var(--accent)]"
                    ]}
                  >
                    {gettext("Mon–Fri")}
                  </button>
                  <button
                    type="button"
                    phx-click="set_planning_days"
                    phx-value-days="7"
                    class={[
                      "px-3 py-1 rounded-full border text-sm font-medium transition-colors",
                      @prefs.planning_days == 7 &&
                        "bg-[color:var(--accent)] border-[color:var(--accent)] text-white",
                      @prefs.planning_days != 7 &&
                        "bg-[color:var(--surface)] border-[color:var(--hairline)] text-[color:var(--muted)] hover:border-[color:var(--accent)]"
                    ]}
                  >
                    {gettext("Mon–Sun")}
                  </button>
                </div>
              </div>
            </div>
          </section>
        </.card>
      </.page>
    </Layouts.app>
    """
  end
end
