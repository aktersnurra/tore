defmodule ToreWeb.HomeLive do
  use ToreWeb, :live_view

  alias Tore.{Recipes, Planning}

  @days ~w[mon tue wed thu fri sat sun]

  def mount(_params, _session, socket) do
    today = Tore.Clock.today()
    week_start = week_start(today)
    scope = socket.assigns.current_scope
    plan_id = Tore.Streams.plan(scope, week_start)
    today_key = today_slot_key(today)

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
       plan_id: plan_id,
       week_start: week_start,
       today_key: today_key,
       tonight_recipe: tonight_recipe,
       eating_out_tonight: Tore.Planning.State.eating_out?(tonight_slot),
       recipes_by_id: recipes_by_id,
       tonight_sheet: false
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} socket={@socket} current_user={@current_user} current_path="/today">
      <%!-- Tonight: the one large thing in the app --%>
      <.page max_width={:md}>
        <section class="pt-6 md:pt-12">
          <p class="section-label">{gettext("Tonight")}</p>

          <div
            :if={@tonight_recipe}
            id="tonight-card"
            phx-hook="LongPress"
            data-long-press-event="open_tonight_sheet"
          >
            <h1
              class="mt-2 font-bold text-[color:var(--text)]"
              style="font-size: clamp(34px, 9vw, 52px); line-height: 1.05; letter-spacing: -0.03em;"
            >
              {@tonight_recipe.title}
            </h1>
            <p
              :if={minutes(@tonight_recipe)}
              class="num mt-3 text-[color:var(--muted)]"
              style="font-size: var(--t-meta);"
            >
              {gettext("%{minutes} min", minutes: minutes(@tonight_recipe))}
            </p>
            <img
              :if={@tonight_recipe.image_path}
              src={~p"/images/recipes/#{@tonight_recipe.id}"}
              alt=""
              class="mt-6 aspect-[4/3] w-full rounded-[var(--r-lg)] object-cover"
            />
            <div class="mt-8 flex gap-3">
              <.link
                navigate={~p"/recipes"}
                class="flex h-12 flex-1 items-center justify-center rounded-[var(--r-md)] bg-[color:var(--accent)] font-semibold text-white transition-colors hover:bg-[color:var(--accent-hover)]"
              >
                {gettext("Start cooking")}
              </.link>
              <button
                type="button"
                phx-click="something_else"
                class="h-12 flex-1 rounded-[var(--r-md)] border border-[color:var(--border)] bg-[var(--surface)] font-semibold text-[color:var(--text)] transition-colors hover:bg-[var(--sunken)]"
              >
                {gettext("Something else")}
              </button>
            </div>
          </div>

          <div :if={!@tonight_recipe}>
            <h1
              class="mt-2 font-bold text-[color:var(--text)]"
              style="font-size: clamp(30px, 8vw, 44px); line-height: 1.1; letter-spacing: -0.03em;"
            >
              {if @eating_out_tonight,
                do: gettext("Eating out tonight"),
                else: gettext("Nothing planned for tonight")}
            </h1>
            <.link
              navigate={~p"/plan"}
              class="mt-8 inline-flex h-12 items-center rounded-[var(--r-md)] border border-[color:var(--border)] bg-[var(--surface)] px-5 font-semibold text-[color:var(--text)] transition-colors hover:bg-[var(--sunken)]"
            >
              {gettext("Open planner")}
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

  defp minutes(recipe) do
    case (recipe.prep_time_minutes || 0) + (recipe.cook_time_minutes || 0) do
      0 -> nil
      total -> total
    end
  end

  defp today_slot_key(today) do
    dow = Date.day_of_week(today)
    day = Enum.at(@days, dow - 1)
    "#{day}_dinner"
  end

  defp week_start(date) do
    dow = Date.day_of_week(date)
    Date.add(date, -(dow - 1))
  end
end
