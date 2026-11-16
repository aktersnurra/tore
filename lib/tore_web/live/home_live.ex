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
       tonight_sheet: false
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
            <.icon name="hero-cog-6-tooth" class="size-5" />
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
              <.icon name="hero-photo" class="size-10" />
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
              <.icon name="hero-fire-solid" /> {gettext("Cook")}
            </.link>
            <.link navigate={~p"/recipes?id=#{@tonight_recipe.id}"} class="pill press">
              <.icon name="hero-book-open" /> {gettext("Recipe")}
            </.link>
            <button type="button" phx-click="something_else" class="pill press">
              <.icon name="hero-arrow-path" /> {gettext("Something else")}
            </button>
            <button type="button" phx-click="open_tonight_sheet" class="pill press">
              <.icon name="hero-chat-bubble-oval-left" /> {gettext("Ask")}
            </button>
          </div>

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
          <div :if={!@eating_out_tonight} class="reveal mt-6 flex flex-wrap gap-2" style="--i: 3">
            <.link navigate={~p"/plan"} class="pill pill-lamp press">
              <.icon name="hero-calendar-days" /> {gettext("Plan the week")}
            </.link>
            <.link navigate={~p"/capture?#{[return_to: "/today"]}"} class="pill press">
              <.icon name="hero-chat-bubble-oval-left" /> {gettext("Ask Tore")}
            </.link>
          </div>
        </section>
      </.page>

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

  defp photo?(recipe), do: recipe != nil and recipe.image_path != nil

  def handle_event("something_else", _params, socket) do
    %{plan_id: plan_id, today_key: today_key, recipes_by_id: recipes_by_id} = socket.assigns
    scope = socket.assigns.current_scope
    Planning.skip_meal(scope, plan_id, today_key)
    {:ok, plan_state} = Planning.load_plan(scope, plan_id)
    tonight_slot = Map.get(plan_state.slots, today_key)

    tonight_recipe =
      if tonight_slot && tonight_slot.recipe_id && !tonight_slot.skipped do
        Map.get(recipes_by_id, tonight_slot.recipe_id)
      end

    {:noreply,
     socket
     |> assign(tonight_recipe: tonight_recipe)
     |> put_flash(:info, gettext("Slot cleared — pick something from the planner."))}
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
