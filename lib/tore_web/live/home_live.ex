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
      <%!-- Tonight: the one large thing in the app --%>
      <.page max_width={:md}>
        <section class={[!photo?(@tonight_recipe) && "pt-6 md:pt-12"]}>
          <%!-- With a picture, the dish is the screen: the name sits on the photograph --%>
          <div
            :if={photo?(@tonight_recipe)}
            id="tonight-card"
            phx-hook="LongPress"
            data-long-press-event="open_tonight_sheet"
          >
            <div class="relative -mx-4 -mt-4 overflow-hidden md:mx-0 md:mt-0">
              <img
                src={~p"/images/recipes/#{@tonight_recipe.id}"}
                alt=""
                class="block aspect-[4/5] max-h-[66vh] w-full object-cover"
              />
              <div class="photo-blur absolute inset-x-0 bottom-0 h-2/5" aria-hidden="true"></div>
              <div class="photo-fade absolute inset-x-0 bottom-0 h-3/4" aria-hidden="true"></div>
              <div class="absolute inset-x-0 bottom-0 px-4 pb-1 md:px-5">
                <p
                  class="num font-semibold text-[color:var(--accent)]"
                  style="font-size: var(--t-meta);"
                >
                  {ToreWeb.Dates.long(@today)}
                </p>
                <h1
                  class="mt-1.5 font-bold text-[color:var(--text)]"
                  style="font-size: 30px; line-height: 1.15; letter-spacing: -0.02em;"
                >
                  {@tonight_recipe.title}
                </h1>
              </div>
            </div>
            <.tonight_actions recipe={@tonight_recipe} servings={@tonight_servings} />
          </div>

          <div
            :if={@tonight_recipe && !photo?(@tonight_recipe)}
            id="tonight-card"
            phx-hook="LongPress"
            data-long-press-event="open_tonight_sheet"
          >
            <p class="num text-[color:var(--muted)]" style="font-size: var(--t-meta);">
              {ToreWeb.Dates.long(@today)}
            </p>
            <h1
              class="mt-3 font-bold text-[color:var(--text)]"
              style="font-size: 30px; line-height: 1.15; letter-spacing: -0.02em;"
            >
              {@tonight_recipe.title}
            </h1>
            <div class="rim mt-6" aria-hidden="true"></div>
            <.tonight_actions recipe={@tonight_recipe} servings={@tonight_servings} />
          </div>

          <div :if={!@tonight_recipe}>
            <p class="num text-[color:var(--muted)]" style="font-size: var(--t-meta);">
              {ToreWeb.Dates.long(@today)}
            </p>
            <h1
              class="mt-3 font-bold text-[color:var(--text)]"
              style="font-size: 30px; line-height: 1.15; letter-spacing: -0.02em;"
            >
              {if @eating_out_tonight,
                do: gettext("Eating out tonight"),
                else: gettext("Tonight is open")}
            </h1>
            <div class="rim mt-6" aria-hidden="true"></div>
            <.link
              navigate={~p"/plan"}
              class="mt-8 inline-flex h-12 items-center rounded-[var(--r-pill)] bg-[color:var(--accent)] px-7 font-semibold text-[color:var(--on-accent)] transition-colors hover:bg-[color:var(--accent-hover)]"
            >
              {gettext("Plan the week")}
            </.link>
          </div>
        </section>
      </.page>

      <%!-- Tonight object sheet (long-press) --%>
      <div
        :if={@tonight_sheet && @tonight_recipe}
        id="tonight-sheet"
        class="fixed inset-x-0 bottom-0 top-8 z-50 rounded-t-[var(--r-xl)] bg-[var(--surface)] border-t border-[color:var(--border)] flex flex-col"
        phx-window-keydown="close_tonight_sheet"
        phx-key="Escape"
      >
        <div class="flex justify-center py-2">
          <button
            type="button"
            phx-click="close_tonight_sheet"
            aria-label={gettext("Close")}
            data-role="tonight-sheet-close"
          >
            <span class="w-10 h-1.5 rounded-full bg-[color:var(--border)] block"></span>
          </button>
        </div>

        <div class="flex items-center gap-3 px-4 py-3 border-b border-[color:var(--border)]">
          <span class="font-semibold text-[color:var(--text)]">{@tonight_recipe.title}</span>
        </div>

        <div class="flex-1 overflow-y-auto px-4 py-4 space-y-4">
          <form phx-submit="tonight_command">
            <input
              type="text"
              name="command"
              autocomplete="off"
              placeholder={gettext("Anything about tonight…")}
              class="w-full rounded-[var(--r-md)] border border-[color:var(--border)] bg-[var(--surface)] px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)]"
            />
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :recipe, :map, required: true
  attr :servings, :integer, default: nil

  defp tonight_actions(assigns) do
    ~H"""
    <dl :if={tonight_facts(@recipe, @servings) != []} class="mt-5 flex gap-8">
      <div :for={{label, value} <- tonight_facts(@recipe, @servings)}>
        <dt class="text-[color:var(--muted)]" style="font-size: var(--t-micro);">{label}</dt>
        <dd class="num font-bold text-[color:var(--text)]" style="font-size: var(--t-body);">
          {value}
        </dd>
      </div>
    </dl>
    <div class="mt-6 flex items-center gap-5">
      <.link
        navigate={~p"/recipes/#{@recipe.id}/cook?from=/today"}
        class="flex h-14 flex-1 items-center justify-center gap-2 rounded-[var(--r-pill)] bg-[color:var(--accent)] px-7 text-[17px] font-semibold text-[color:var(--on-accent)] transition-colors hover:bg-[color:var(--accent-hover)]"
      >
        <.icon name="hero-fire" class="size-5" />
        {gettext("Start cooking")}
      </.link>
      <button
        type="button"
        phx-click="something_else"
        class="h-14 shrink-0 font-semibold text-[color:var(--muted)] underline-offset-4 hover:text-[color:var(--text)] hover:underline"
      >
        {gettext("Something else")}
      </button>
    </div>
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
