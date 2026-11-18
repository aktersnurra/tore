defmodule ToreWeb.HomeLive do
  use ToreWeb, :live_view

  alias Tore.{Recipes, Planning}

  def mount(_params, _session, socket) do
    today = Tore.Clock.today()
    week_start = Tore.Streams.monday(today)
    scope = socket.assigns.current_scope
    plan_id = Tore.Streams.plan(scope, week_start)
    today_key = Tore.Streams.slot_key(today)

    {:ok,
     socket
     |> assign(
       today: today,
       plan_id: plan_id,
       week_start: week_start,
       today_key: today_key,
       tonight_sheet: false,
       choices: nil,
       changed: nil
     )
     |> reload_tonight()}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <.page max_width={:sm}>
        <div class="relative z-10 h-0">
          <.top_bar on_photo={@tonight_recipe != nil} class="absolute inset-x-0 -top-2">
            <:actions :if={@tonight_recipe}>
              <.page_menu id="today-menu" on_photo>
                <.menu_item
                  menu="today-menu"
                  icon="ph-book-open"
                  navigate={~p"/recipes?#{[id: @tonight_recipe.id]}"}
                >
                  {gettext("Open the recipe")}
                </.menu_item>
                <.menu_item menu="today-menu" icon="ph-chat-circle" event="open_tonight_sheet">
                  {gettext("Ask about tonight")}
                </.menu_item>
                <.menu_item menu="today-menu" icon="ph-x-circle" event="skip_tonight">
                  {gettext("No dinner tonight")}
                </.menu_item>
              </.page_menu>
            </:actions>
          </.top_bar>
        </div>

        <%!-- Tonight: the dish is the screen --%>
        <section
          :if={@tonight_recipe}
          id="tonight-card"
          phx-hook="LongPress"
          data-long-press-event="open_tonight_sheet"
        >
          <%!-- The cover: tonight's photo, or the dish's tinted icon while one is drawn --%>
          <div class="relative -mx-4 -mt-4 h-[32svh] min-h-[210px] max-h-[300px] overflow-hidden md:mx-0 md:mt-0 md:rounded-[var(--r-xl)]">
            <img
              :if={photo?(@tonight_recipe)}
              src={~p"/images/recipes/#{@tonight_recipe.id}"}
              alt=""
              class="absolute inset-0 size-full object-cover"
              style={"view-transition-name: dish-#{@tonight_recipe.id}"}
            />
            <.blank_cover :if={!photo?(@tonight_recipe)} dish={@tonight_recipe} icon_class="size-20" />
          </div>

          <div class="reveal relative -mt-9" style="--i: 0">
            <.page_icon
              icon={ToreWeb.Look.icon(@tonight_recipe)}
              tint={ToreWeb.Look.tint(@tonight_recipe.recipe_type)}
              class="size-[72px] rounded-[var(--r-xl)] ring-4 ring-[var(--bg)]"
            />
          </div>
          <h1 class="reveal t-display mt-3" style="--i: 1">{@tonight_recipe.title}</h1>

          <dl class="props reveal mt-4" style="--i: 2">
            <div>
              <dt><.icon name="ph-calendar-blank" /> {gettext("Day")}</dt>
              <dd class="flex items-center gap-2">
                <span class="tag tag-red">{gettext("Tonight")}</span>
                <span class="num text-[color:var(--muted)]">{ToreWeb.Dates.long(@today)}</span>
              </dd>
            </div>
            <div>
              <dt><.icon name="ph-tag" /> {gettext("Collection")}</dt>
              <dd>
                <span class={["tag", "tag-#{ToreWeb.Look.tint(@tonight_recipe.recipe_type)}"]}>
                  <.icon name={ToreWeb.Look.collection_icon(@tonight_recipe.recipe_type)} />
                  {collection_label(@tonight_recipe.recipe_type)}
                </span>
              </dd>
            </div>
            <div :if={minutes(@tonight_recipe) > 0}>
              <dt><.icon name="ph-clock" /> {gettext("Time")}</dt>
              <dd class="num">
                {gettext("%{minutes} min", minutes: minutes(@tonight_recipe))}
                <span class="text-[color:var(--muted)]">
                  · {gettext("ready by %{time}", time: ready_by(minutes(@tonight_recipe)))}
                </span>
              </dd>
            </div>
            <div :if={@tonight_servings}>
              <dt><.icon name="ph-users" /> {gettext("Servings")}</dt>
              <dd class="num">{@tonight_servings}</dd>
            </div>
            <div :if={@tonight_recipe.recipe_ingredients != []} data-role="at-home">
              <dt><.icon name="ph-jar" /> {gettext("At home")}</dt>
              <dd :if={@home.missing == []} class="font-semibold text-[color:var(--done)]">
                {gettext("All of it")}
              </dd>
              <dd :if={@home.missing != []} class="flex flex-wrap items-center gap-1.5 py-1.5">
                <span class="sr-only">
                  {gettext("Missing: %{things}", things: Enum.join(@home.missing, ", "))}
                </span>
                <span :for={thing <- @home.missing} class="tag tag-red" aria-hidden="true">
                  {thing}
                </span>
                <button
                  :if={!@home_added}
                  type="button"
                  phx-click="add_missing"
                  class="press text-[color:var(--muted)] underline decoration-[color:var(--subtle)] underline-offset-4 hover:text-[color:var(--text)]"
                  style="font-size: 14px;"
                >
                  {gettext("Put on the list")}
                </button>
                <.link
                  :if={@home_added}
                  id="home-added"
                  navigate={~p"/shop"}
                  class="settle inline-flex items-center gap-1 font-semibold text-[color:var(--done)]"
                  style="font-size: 14px;"
                >
                  <.icon name="ph-check" class="size-4" /> {gettext("On the list")}
                </.link>
              </dd>
            </div>
          </dl>

          <div class="reveal mt-5 flex gap-2" style="--i: 3">
            <.link
              navigate={~p"/recipes/#{@tonight_recipe.id}/cook?from=/today"}
              class="pill pill-lamp press"
              data-role="start-cooking"
            >
              <.icon name="ph-fire-fill" /> {gettext("Cook now")}
            </.link>
            <button type="button" phx-click="something_else" class="pill press">
              <.icon name="ph-arrows-left-right" /> {gettext("Something else")}
            </button>
          </div>

          <p
            :if={@changed}
            id="tonight-changed"
            class="settle mt-4 flex items-center gap-3 text-[color:var(--muted)]"
            style="font-size: 15px;"
          >
            <span :if={@changed.from}>{gettext("Instead of %{dish}.", dish: @changed.from)}</span>
            <button
              type="button"
              phx-click="undo_tonight"
              class="press font-semibold text-[color:var(--accent-ink)]"
            >
              {gettext("Undo")}
            </button>
          </p>

          <section :if={@tonight_recipe.recipe_ingredients != []} class="reveal mt-8" style="--i: 4">
            <h2 class="t-head mb-1">{gettext("Ingredients")}</h2>
            <ul class="menu-lines">
              <li
                :for={ri <- @tonight_recipe.recipe_ingredients}
                class="flex items-baseline justify-between gap-4 py-3"
              >
                <span class="text-[color:var(--text)]" style="font-size: 16px;">
                  {ri.ingredient.name}
                </span>
                <span class="num shrink-0 text-[color:var(--muted)]" style="font-size: 15px;">
                  {amount(ri, @tonight_recipe.base_servings, @tonight_servings)}
                </span>
              </li>
            </ul>
          </section>
        </section>

        <%!-- Nothing tonight: say so plainly, and offer the way forward --%>
        <section :if={!@tonight_recipe} class="pt-20">
          <p class="reveal t-eyebrow num" style="--i: 0">{ToreWeb.Dates.long(@today)}</p>
          <h1 class="reveal t-display mt-2" style="--i: 1">
            {if @eating_out_tonight,
              do: gettext("Eating out tonight"),
              else: gettext("Tonight is open")}
          </h1>
          <p
            :if={!@eating_out_tonight}
            class="reveal mt-3 max-w-[30ch] text-[color:var(--muted)]"
            style="--i: 2; font-size: 15px; line-height: 1.5;"
          >
            {gettext("Plan the week, or ask Tore what to make tonight.")}
          </p>
          <p :if={@changed} class="settle mt-4 text-[color:var(--muted)]" style="font-size: 15px;">
            <button
              type="button"
              phx-click="undo_tonight"
              class="press font-semibold text-[color:var(--accent-ink)]"
            >
              {gettext("Undo")}
            </button>
          </p>
          <div :if={!@eating_out_tonight} class="reveal mt-6 flex flex-wrap gap-2" style="--i: 3">
            <button type="button" phx-click="something_else" class="pill pill-lamp press">
              <.icon name="ph-lightbulb" /> {gettext("Suggest something")}
            </button>
            <.link navigate={~p"/plan"} class="pill press">
              <.icon name="ph-calendar-blank" /> {gettext("Plan the week")}
            </.link>
            <.link navigate={~p"/capture?#{[return_to: "/today"]}"} class="pill press">
              <.icon name="ph-chat-circle" /> {gettext("Ask Tore")}
            </.link>
          </div>
        </section>
      </.page>

      <%!-- Something else tonight: a few dishes to choose between, or none --%>
      <.bottom_sheet :if={@choices} id="choices-sheet" on_close="close_choices" class="px-5">
        <p class="t-eyebrow">{gettext("Tonight")}</p>
        <p class="t-head mt-1">{gettext("Something else?")}</p>
        <div class="mt-4">
          <ToreWeb.DishChoices.dish_choices
            choices={@choices.list}
            event="choose_tonight"
            loading={@choices.loading}
          />
          <p
            :if={!@choices.loading and @choices.list == []}
            class="py-2 text-[color:var(--muted)]"
            style="font-size: 15px;"
          >
            {gettext("Nothing else in the recipes right now. Ask Tore for an idea.")}
          </p>
        </div>
        <div class="mt-4 flex items-center justify-between border-t border-[color:var(--hairline)] pt-3">
          <button
            :if={@tonight_recipe}
            type="button"
            phx-click="skip_tonight"
            class="press py-2 text-[color:var(--muted)] hover:text-[color:var(--text)]"
            style="font-size: 15px;"
          >
            {gettext("No dinner tonight")}
          </button>
          <.link
            navigate={~p"/capture?#{[return_to: "/today"]}"}
            class="press ml-auto py-2 font-semibold text-[color:var(--text)]"
            style="font-size: 15px;"
          >
            {gettext("Ask Tore")}
          </.link>
        </div>
      </.bottom_sheet>

      <%!-- Anything about tonight, asked in words (Ask, or a long press) --%>
      <.bottom_sheet
        :if={@tonight_sheet && @tonight_recipe}
        id="tonight-sheet"
        on_close="close_tonight_sheet"
        class="px-5"
      >
        <p class="t-eyebrow">{gettext("Tonight")}</p>
        <p class="t-head mt-1">{@tonight_recipe.title}</p>
        <form phx-submit="tonight_command" class="mt-4">
          <input
            type="text"
            name="command"
            autocomplete="off"
            autofocus
            placeholder={gettext("Anything about tonight…")}
            class="h-12 w-full rounded-full bg-[var(--sunken)] px-5 text-[color:var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus-visible:outline-2 focus-visible:outline-[color:var(--accent)]"
            style="font-size: 16px;"
          />
        </form>
      </.bottom_sheet>
    </Layouts.app>
    """
  end

  defp change_tonight(socket, change) do
    %{current_scope: scope, plan_id: plan_id, today_key: key, tonight_recipe: from} =
      socket.assigns

    {:ok, state} = Planning.load_plan(scope, plan_id)
    before = Planning.slots_before(state, [key])
    {:ok, _} = change.(scope, plan_id, key)

    {:noreply,
     socket
     |> reload_tonight()
     |> assign(choices: nil, changed: %{before: before, from: from && from.title})}
  end

  defp reload_tonight(socket) do
    %{current_scope: scope, plan_id: plan_id, today_key: key} = socket.assigns
    {:ok, state} = Planning.load_plan(scope, plan_id)
    slot = Map.get(state.slots, key)

    tonight =
      if slot && slot.recipe_id && !slot.skipped,
        do: scope |> Recipes.get_many([slot.recipe_id]) |> List.first()

    assign(socket,
      tonight_recipe: tonight,
      tonight_servings: slot && slot[:servings],
      eating_out_tonight: Tore.Planning.State.eating_out?(slot),
      home:
        tonight &&
          Tore.Pantry.at_home(scope, Enum.map(tonight.recipe_ingredients, & &1.ingredient.name)),
      home_added: false
    )
  end

  # What tonight needs and the house doesn't have goes on this week's list.
  def handle_event("add_missing", _params, %{assigns: %{home_added: false, home: %{}}} = socket) do
    %{current_scope: scope, current_user: user, home: home, week_start: monday} = socket.assigns
    list_id = Tore.Streams.shop_list(scope, monday)
    for name <- home.missing, do: Tore.Shop.add_item(scope, list_id, name, nil, nil, user.id)
    {:noreply, assign(socket, home_added: true)}
  end

  def handle_event("add_missing", _params, socket), do: {:noreply, socket}

  # A few other dishes for tonight, ranked from the library (no model is asked).
  def handle_event("something_else", _params, socket) do
    %{current_scope: scope, plan_id: plan_id, today_key: key, tonight_recipe: tonight} =
      socket.assigns

    ToreWeb.Background.run(
      fn -> Planning.suggest_recipes_for_slot(scope, plan_id, key, limit: 4) end,
      fn
        {:ok, suggestions} -> {:choices, suggestions}
        _ -> {:choices, []}
      end
    )

    {:noreply,
     assign(socket, choices: %{list: [], loading: true, without: tonight && tonight.id})}
  end

  def handle_event("close_choices", _params, socket), do: {:noreply, assign(socket, choices: nil)}

  # Tonight becomes the chosen dish, for the servings it had; Undo puts tonight back.
  def handle_event("choose_tonight", %{"id" => id}, socket) do
    change_tonight(socket, fn scope, plan_id, key ->
      Planning.assign_recipe(
        scope,
        plan_id,
        key,
        String.to_integer(id),
        socket.assigns.tonight_servings || 4
      )
    end)
  end

  def handle_event("skip_tonight", _params, socket) do
    change_tonight(socket, fn scope, plan_id, key -> Planning.skip_meal(scope, plan_id, key) end)
  end

  def handle_event("undo_tonight", _params, %{assigns: %{changed: %{} = changed}} = socket) do
    :ok =
      Planning.restore_slots(socket.assigns.current_scope, socket.assigns.plan_id, changed.before)

    {:noreply, socket |> reload_tonight() |> assign(changed: nil)}
  end

  def handle_event("open_tonight_sheet", _params, socket) do
    if socket.assigns.tonight_recipe do
      {:noreply, assign(socket, tonight_sheet: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_tonight_sheet", _params, socket) do
    {:noreply, assign(socket, tonight_sheet: false)}
  end

  def handle_event("tonight_command", %{"command" => command}, socket) when command != "" do
    scope = socket.assigns.current_scope

    ctx = %{
      command: command,
      plan_stream_id: socket.assigns.plan_id,
      week_start: socket.assigns.week_start,
      scoped_slot: socket.assigns.today_key
    }

    ToreWeb.Background.run(
      fn -> Tore.Harness.Runs.start(scope, Tore.Harness.Kinds.PlannerCommand, ctx) end,
      &{:run_dispatched, &1}
    )

    {:noreply, assign(socket, tonight_sheet: false)}
  end

  def handle_event("tonight_command", _params, socket), do: {:noreply, socket}

  def handle_info({:choices, suggestions}, %{assigns: %{choices: %{} = choices}} = socket) do
    list = suggestions |> Enum.reject(&(&1.recipe.id == choices.without)) |> Enum.take(3)
    {:noreply, assign(socket, choices: %{choices | list: list, loading: false})}
  end

  def handle_info({:choices, _suggestions}, socket), do: {:noreply, socket}

  def handle_info({:run_dispatched, result}, socket) do
    socket =
      socket
      |> reload_tonight()
      |> then(fn socket ->
        case result do
          {:ok, _} ->
            put_flash(socket, :info, gettext("Done."))

          {:error, reason} ->
            put_flash(
              socket,
              :error,
              Tore.LLM.refusal_text(reason) ||
                gettext("Tore couldn't finish that. Try again in a moment.")
            )
        end
      end)

    {:noreply, socket}
  end

  defp photo?(recipe), do: recipe != nil and recipe.image_path != nil

  defp minutes(recipe), do: (recipe.prep_time_minutes || 0) + (recipe.cook_time_minutes || 0)

  defp collection_label(:meal), do: gettext("Dinner")
  defp collection_label(:baking), do: gettext("Baking")
  defp collection_label(:component), do: gettext("Sauces & sides")
  defp collection_label(:assembly), do: gettext("Assemblies")

  defp amount(ri, base, servings) do
    quantity = Recipes.scale_quantity(ri.quantity, base, servings || base)
    unit = if ri.unit not in [nil, ""], do: " #{ri.unit}"
    "#{quantity}#{unit}"
  end

  defp ready_by(minutes),
    do: Tore.Clock.now() |> NaiveDateTime.add(minutes, :minute) |> Calendar.strftime("%H:%M")
end
