defmodule ToreWeb.HomeLive do
  use ToreWeb, :live_view

  alias Tore.{Recipes, Planning}

  def mount(_params, _session, socket) do
    today = Tore.Clock.today()
    week_start = Tore.Streams.monday(today)
    scope = socket.assigns.current_scope
    plan_id = Tore.Streams.plan(scope, week_start)
    today_key = Tore.Streams.slot_key(today)

    {:ok, plan_state} = Planning.load_plan(scope, plan_id)

    recipes = Recipes.list(socket.assigns.current_scope)
    recipes_by_id = Map.new(recipes, &{&1.id, &1})

    tonight_slot = Map.get(plan_state.slots, today_key)

    tonight_recipe =
      if tonight_slot && tonight_slot.recipe_id && !tonight_slot.skipped do
        Map.get(recipes_by_id, tonight_slot.recipe_id)
      end

    {:ok,
     assign(socket,
       today: today,
       plan_id: plan_id,
       week_start: week_start,
       today_key: today_key,
       tonight_recipe: tonight_recipe,
       tonight_servings: tonight_slot && tonight_slot[:servings],
       eating_out_tonight: Tore.Planning.State.eating_out?(tonight_slot),
       recipes_by_id: recipes_by_id,
       tonight_sheet: false,
       choices: nil,
       changed: nil
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user}>
      <.page max_width={:sm}>
        <div class="relative z-10 h-0">
          <.link
            navigate={~p"/settings"}
            aria-label={gettext("Settings")}
            data-role="settings-link"
            class="on-photo press absolute top-0 right-0"
          >
            <.icon name="ph-gear-six" class="size-5" />
          </.link>
        </div>

        <%!-- Tonight: the dish is the screen --%>
        <section
          :if={@tonight_recipe}
          id="tonight-card"
          phx-hook="LongPress"
          data-long-press-event="open_tonight_sheet"
        >
          <div class="relative -mx-4 -mt-4 h-[64svh] min-h-[400px] max-h-[620px] overflow-hidden bg-[var(--sunken)] md:mx-0 md:mt-0 md:rounded-[28px]">
            <img
              :if={photo?(@tonight_recipe)}
              src={~p"/images/recipes/#{@tonight_recipe.id}"}
              alt=""
              class="absolute inset-0 size-full object-cover"
              style={"view-transition-name: dish-#{@tonight_recipe.id}"}
            />
            <div
              :if={!photo?(@tonight_recipe)}
              class="absolute inset-0 flex items-center justify-center text-[color:var(--subtle)]"
            >
              <.icon name="ph-image" class="size-10" />
            </div>
            <div class="photo-foot absolute inset-x-0 bottom-0 h-3/5" aria-hidden="true"></div>
            <div class="absolute inset-x-0 bottom-0 px-4 pb-1 md:px-5">
              <p class="reveal t-eyebrow num" style="--i: 0">
                {gettext("Dinner")} · {ToreWeb.Dates.long(@today)}
              </p>
              <h1 class="reveal t-display mt-2" style="--i: 1">{@tonight_recipe.title}</h1>
            </div>
          </div>

          <div
            class="reveal scroll-quiet -mx-4 mt-5 flex gap-2 overflow-x-auto px-4 md:mx-0 md:px-0"
            style="--i: 2"
          >
            <.link
              navigate={~p"/recipes/#{@tonight_recipe.id}/cook?from=/today"}
              class="pill pill-lamp press"
              data-role="start-cooking"
            >
              <.icon name="ph-fire-fill" /> {gettext("Cook")}
            </.link>
            <.link navigate={~p"/recipes?id=#{@tonight_recipe.id}"} class="pill press">
              <.icon name="ph-book-open" /> {gettext("Recipe")}
            </.link>
            <button type="button" phx-click="something_else" class="pill press">
              <.icon name="ph-arrows-clockwise" /> {gettext("Something else")}
            </button>
            <button type="button" phx-click="open_tonight_sheet" class="pill press">
              <.icon name="ph-chat-circle" /> {gettext("Ask")}
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

          <p
            :if={@tonight_recipe.description not in [nil, ""]}
            class="reveal mt-5 line-clamp-3 text-[color:var(--muted)]"
            style="--i: 3; font-size: 15px; line-height: 1.5;"
          >
            {@tonight_recipe.description}
          </p>

          <dl
            :if={tonight_facts(@tonight_recipe, @tonight_servings) != []}
            class="facts reveal mt-5 border-t border-[color:var(--hairline)] pt-4"
            style="--i: 4"
          >
            <div :for={{label, value} <- tonight_facts(@tonight_recipe, @tonight_servings)}>
              <dt>{label}</dt>
              <dd>{value}</dd>
            </div>
          </dl>
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
      if slot && slot.recipe_id && !slot.skipped, do: Recipes.get(scope, slot.recipe_id)

    assign(socket,
      tonight_recipe: tonight,
      tonight_servings: slot && slot[:servings],
      eating_out_tonight: Tore.Planning.State.eating_out?(slot)
    )
  end

  defp photo?(recipe), do: recipe != nil and recipe.image_path != nil

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
    %{plan_id: plan_id, today_key: today_key, recipes_by_id: recipes_by_id} = socket.assigns
    {:ok, plan_state} = Planning.load_plan(socket.assigns.current_scope, plan_id)
    tonight_slot = Map.get(plan_state.slots, today_key)

    tonight_recipe =
      if tonight_slot && tonight_slot.recipe_id && !tonight_slot.skipped do
        Map.get(recipes_by_id, tonight_slot.recipe_id)
      end

    socket =
      socket
      |> assign(tonight_recipe: tonight_recipe)
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

  # The few facts worth a glance before starting: how long, for how many, when it's on the table.
  defp tonight_facts(recipe, servings) do
    minutes = (recipe.prep_time_minutes || 0) + (recipe.cook_time_minutes || 0)

    [
      minutes > 0 && {gettext("Time"), gettext("%{minutes} min", minutes: minutes)},
      servings && {gettext("Servings"), to_string(servings)},
      minutes > 0 && {gettext("Ready by"), ready_by(minutes)}
    ]
    |> Enum.filter(& &1)
  end

  defp ready_by(minutes),
    do: Tore.Clock.now() |> NaiveDateTime.add(minutes, :minute) |> Calendar.strftime("%H:%M")
end
