defmodule ToreWeb.HomeLive do
  use ToreWeb, :live_view

  alias Tore.{Recipes, Planning}

  @days ~w[mon tue wed thu fri sat sun]

  def mount(_params, _session, socket) do
    today = Date.utc_today()
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
    <Layouts.app flash={@flash} current_path="/">
      <.link
        :if={@inbox_count > 0}
        href={~p"/review"}
        data-role="review-pill"
        class="inline-flex items-center gap-2 px-4 h-9 rounded-full border border-[color:var(--border)] bg-[var(--surface)] text-sm text-[var(--text)] mb-4"
      >
        {ngettext("%{count} to review", "%{count} to review", @inbox_count, count: @inbox_count)}
      </.link>

      <%!-- Tonight card --%>
      <section class="mb-6">
        <h2 class="text-xs font-semibold uppercase tracking-wider text-[color:var(--muted)] mb-3">
          {gettext("Tonight")}
        </h2>

        <div
          :if={@tonight_recipe}
          id="tonight-card"
          phx-hook="LongPress"
          data-long-press-event="open_tonight_sheet"
          class="rounded-2xl bg-[var(--surface)] border border-[color:var(--border)] overflow-hidden"
        >
          <div class="w-full h-48 bg-[var(--border)] flex items-center justify-center text-[color:var(--muted)] text-sm">
            {gettext("No photo")}
          </div>
          <div class="p-4">
            <p class="text-xl font-semibold text-[color:var(--text)]">{@tonight_recipe.title}</p>
            <div class="mt-4 flex gap-3">
              <.link
                navigate={~p"/recipes"}
                class="flex-1 rounded-xl bg-[color:var(--accent)] text-white text-center py-3 text-sm font-semibold"
              >
                {gettext("Start cooking")}
              </.link>
              <button
                phx-click="something_else"
                class="flex-1 rounded-xl border border-[color:var(--border)] text-[color:var(--text)] py-3 text-sm font-semibold"
              >
                {gettext("Something else")}
              </button>
            </div>
          </div>
        </div>

        <div
          :if={!@tonight_recipe}
          class="rounded-2xl bg-[var(--surface)] border border-[color:var(--border)] p-6 text-center text-[color:var(--muted)] text-sm"
        >
          {if @eating_out_tonight,
            do: gettext("Eating out tonight"),
            else: gettext("Nothing planned for tonight")}
          <div class="mt-4">
            <.link navigate={~p"/plan"} class="text-[color:var(--accent)] font-semibold text-sm">
              {gettext("Open planner")}
            </.link>
          </div>
        </div>
      </section>

      <%!-- Tonight object sheet (long-press) --%>
      <div
        :if={@tonight_sheet && @tonight_recipe}
        id="tonight-sheet"
        class="fixed inset-x-0 bottom-0 top-8 z-50 rounded-t-2xl bg-[var(--surface)] border-t border-[color:var(--border)] flex flex-col"
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
              class="w-full rounded-lg border border-zinc-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
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
    pid = self()

    ctx = %{
      household_id: socket.assigns.current_scope.household_id,
      user_id: socket.assigns.current_user.id,
      command: command,
      plan_stream_id: socket.assigns.plan_id,
      week_start: socket.assigns.week_start,
      scoped_slot: socket.assigns.today_key
    }

    Task.start(fn ->
      result =
        try do
          Tore.Harness.Orchestrator.dispatch(:planner_command_run, ctx)
        rescue
          e -> {:error, e}
        end

      send(pid, {:run_dispatched, result})
    end)

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

          {:error, _} ->
            put_flash(
              socket,
              :error,
              gettext("Tore couldn't finish that. Try again in a moment.")
            )
        end
      end)

    {:noreply, socket}
  end

  # Every signed-in page hears about runs, for the review count.
  def handle_info({:run_event, _stream_id, _event}, socket), do: {:noreply, socket}
  def handle_info({:run_state_changed, _stream_id, _state}, socket), do: {:noreply, socket}

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
