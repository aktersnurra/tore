# Phase 3 — Home Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the cooking-mode home screen — tonight hero + week strip + FAB stub.

**Architecture:** New `HomeLive` LiveView at `/`. Tonight's slot is read from plan state for today. The slot key is `"<dow>_dinner"` where `<dow>` is derived from `Date.day_of_week/1` mapped through `@days = ~w[mon tue wed thu fri sat sun]`. Week strip maps all 7 days. Counter notes with `surface: "home"` render above the tonight card. FAB is a visible button stub (Phase 4 connects it). PlannerLive moves to `/plan`. Nav item for `/` becomes "Home" with icon `nav-home`; the former "Week" entry becomes `/plan` with icon `nav-week`.

**Tech Stack:** Elixir/Phoenix/LiveView, TailwindCSS, existing `PlanningHandler`, `CounterNotes`, `Recipes`

---

## Task 1 — Router + nav

- [ ] In `lib/tore_web/router.ex`, change `live "/", PlannerLive` to `live "/", HomeLive` and add `live "/plan", PlannerLive` inside the `:authenticated` live_session block.
- [ ] In `lib/tore_web/components/layouts.ex`, update `nav_items/0`:
  - Replace `{"/", gettext("Week"), "nav-week"}` with two entries:
    - `{"/", gettext("Home"), "nav-home"}`
    - `{"/plan", gettext("Week"), "nav-week"}`
  - Update the `grid-cols-9` on the mobile `<nav>` to `grid-cols-10` (one extra item).
- [ ] Fix `active?/2` — the existing clause `defp active?(current, "/"), do: current == "/"` already handles exact match for `/`, so `/plan` will work correctly via the `String.starts_with?` fallback. No change needed there.
- [ ] Verify compile: `mix compile --warnings-as-errors`.

**Commit:** `jj describe -m "feat: add HomeLive route at / and move PlannerLive to /plan"`

---

## Task 2 — HomeLive mount + tonight card

- [ ] Create `lib/tore_web/live/home_live.ex`:

```elixir
defmodule ToreWeb.HomeLive do
  use ToreWeb, :live_view

  alias Tore.{Recipes, Handlers.PlanningHandler, CounterNotes}

  @days ~w[mon tue wed thu fri sat sun]

  def mount(_params, _session, socket) do
    today = Date.utc_today()
    week_start = week_start(today)
    plan_id = plan_id(week_start)
    today_key = today_slot_key(today)

    {:ok, plan_state} = PlanningHandler.load_plan(plan_id)

    tonight_slot = Map.get(plan_state.slots, today_key)
    tonight_recipe =
      if tonight_slot && tonight_slot.recipe_id && !tonight_slot.skipped do
        Recipes.get(tonight_slot.recipe_id)
      end

    home_notes = CounterNotes.list_for_surface("home")

    {:ok,
     assign(socket,
       today: today,
       week_start: week_start,
       plan_id: plan_id,
       today_key: today_key,
       plan_state: plan_state,
       tonight_slot: tonight_slot,
       tonight_recipe: tonight_recipe,
       home_notes: home_notes
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path="/">
      <%!-- Counter notes for home surface --%>
      <div :if={@home_notes != []} class="mb-4 flex flex-col gap-2">
        <div
          :for={note <- @home_notes}
          class="rounded-lg px-4 py-3 bg-[var(--surface)] border border-[color:var(--border)] text-sm text-[color:var(--text)]"
        >
          {note.body}
        </div>
      </div>

      <%!-- Tonight card --%>
      <section class="mb-6">
        <h2 class="text-xs font-semibold uppercase tracking-wider text-[color:var(--muted)] mb-3">
          {gettext("Tonight")}
        </h2>

        <div :if={@tonight_recipe} class="rounded-2xl bg-[var(--surface)] border border-[color:var(--border)] overflow-hidden">
          <%!-- Photo placeholder — replaced when Phase 2 Garage lands --%>
          <div class="w-full h-48 bg-[var(--border)] flex items-center justify-center text-[color:var(--muted)] text-sm">
            {gettext("No photo")}
          </div>
          <div class="p-4">
            <p class="text-xl font-semibold text-[color:var(--text)]">{@tonight_recipe.title}</p>
            <div class="mt-4 flex gap-3">
              <.link
                navigate={~p"/recipes/#{@tonight_recipe.id}"}
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

        <div :if={!@tonight_recipe} class="rounded-2xl bg-[var(--surface)] border border-[color:var(--border)] p-6 text-center text-[color:var(--muted)] text-sm">
          {gettext("Nothing planned for tonight")}
          <div class="mt-4">
            <.link navigate={~p"/plan"} class="text-[color:var(--accent)] font-semibold text-sm">
              {gettext("Open planner")}
            </.link>
          </div>
        </div>
      </section>

      <%!-- Week strip --%>
      <.week_strip plan_state={@plan_state} week_start={@week_start} today={@today} />

      <%!-- FAB --%>
      <button
        phx-click="open_chat"
        class="fixed bottom-20 right-4 md:bottom-6 z-30 flex items-center gap-2 rounded-full bg-[color:var(--accent)] text-white px-5 py-3 shadow-lg text-sm font-semibold"
        aria-label={gettext("Ask Tore")}
      >
        <.icon name="hero-chat-bubble-left-ellipsis" class="size-5" />
        {gettext("Ask Tore")}
      </button>
    </Layouts.app>
    """
  end

  def handle_event("something_else", _params, socket) do
    %{plan_id: plan_id, today_key: today_key, week_start: week_start} = socket.assigns
    PlanningHandler.skip_meal(plan_id, today_key)
    {:ok, plan_state} = PlanningHandler.load_plan(plan_id)
    tonight_slot = Map.get(plan_state.slots, today_key)
    tonight_recipe =
      if tonight_slot && tonight_slot.recipe_id && !tonight_slot.skipped do
        Recipes.get(tonight_slot.recipe_id)
      end
    {:noreply,
     socket
     |> assign(plan_state: plan_state, tonight_slot: tonight_slot, tonight_recipe: tonight_recipe)
     |> put_flash(:info, gettext("Slot cleared — pick something from the planner."))}
  end

  def handle_event("open_chat", _params, socket) do
    # Phase 4 wires this — stub for now
    {:noreply, socket}
  end

  attr :plan_state, :map, required: true
  attr :week_start, :any, required: true
  attr :today, :any, required: true

  defp week_strip(assigns) do
    days = ~w[mon tue wed thu fri sat sun]
    dates = Enum.with_index(days, fn day, i -> {day, Date.add(assigns.week_start, i)} end)
    assigns = assign(assigns, :days_with_dates, dates)

    ~H"""
    <section>
      <h2 class="text-xs font-semibold uppercase tracking-wider text-[color:var(--muted)] mb-3">
        {gettext("This week")}
      </h2>
      <div class="flex gap-2 overflow-x-auto pb-2 -mx-4 px-4 snap-x">
        <.link
          :for={{day, date} <- @days_with_dates}
          navigate={~p"/plan"}
          class={[
            "snap-start shrink-0 w-24 rounded-xl border p-3 flex flex-col gap-1 transition-colors",
            date == @today && "border-[color:var(--accent)] bg-[var(--accent)]/10",
            date != @today && "border-[color:var(--border)] bg-[var(--surface)]"
          ]}
        >
          <span class={[
            "text-xs font-semibold uppercase tracking-wide",
            date == @today && "text-[color:var(--accent)]",
            date != @today && "text-[color:var(--muted)]"
          ]}>
            {day_abbr(date)}
          </span>
          <%!-- Photo placeholder (grey box) --%>
          <div class="w-full h-12 rounded-lg bg-[var(--border)]" />
          <span class="text-xs text-[color:var(--text)] truncate leading-tight">
            {slot_title(@plan_state, "#{day}_dinner")}
          </span>
        </.link>
      </div>
    </section>
    """
  end

  defp slot_title(plan_state, slot_key) do
    slot = Map.get(plan_state.slots, slot_key)
    cond do
      is_nil(slot) || is_nil(slot.recipe_id) -> "—"
      slot.skipped -> gettext("Skipped")
      true ->
        # title stored on slot struct if present; fall back to "—"
        slot.recipe_title || "—"
    end
  end

  defp day_abbr(date) do
    case Date.day_of_week(date) do
      1 -> gettext("Mon")
      2 -> gettext("Tue")
      3 -> gettext("Wed")
      4 -> gettext("Thu")
      5 -> gettext("Fri")
      6 -> gettext("Sat")
      7 -> gettext("Sun")
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

  defp plan_id(week_start), do: "plan:#{Date.to_iso8601(week_start)}"
end
```

> **Note on `slot.recipe_title`:** Inspect the `PlanState` slot struct fields before writing. If the slot only stores `recipe_id` (not title), adjust `slot_title/2` to look up into a `recipes` map — you may need to add `recipes: Recipes.list(sort: :alphabetical)` to the mount assigns and build a `recipes_by_id` map.

- [ ] Verify compile.

**Commit:** `jj describe -m "feat: HomeLive mount, tonight card, week strip, FAB stub"`

---

## Task 3 — Tests for HomeLive

Create `test/tore_web/live/home_live_test.exs`:

```elixir
defmodule ToreWeb.HomeLiveTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Tore.Accounts

  setup do
    {:ok, {user, _code}} = Accounts.create_admin("Gustaf")
    conn = build_conn() |> Plug.Test.init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  test "mounts without crash and shows tonight section", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ gettext("Tonight")
  end

  test "shows 'Nothing planned for tonight' when no recipe assigned", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ gettext("Nothing planned for tonight")
  end

  test "week strip renders 7 day chips", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    for day <- ~w[Mon Tue Wed Thu Fri Sat Sun] do
      assert html =~ day
    end
  end

  test "FAB renders with Ask Tore label", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ gettext("Ask Tore")
  end
end
```

- [ ] Run `mix test test/tore_web/live/home_live_test.exs` — all 4 pass.
- [ ] Run `mix test test/tore_web/live/planner_live_test.exs` — all pass (PlannerLive now at `/plan`; update any test that visits `~p"/"` to visit `~p"/plan"`).

**Commit:** `jj describe -m "test: HomeLive mount, week strip, FAB, nothing-planned cases"`

---

## Task 4 — FAB on PlannerLive

- [ ] Add the same FAB button to the `PlannerLive` render (inside `<Layouts.app>`), below all other content:

```heex
<button
  phx-click="open_chat"
  class="fixed bottom-20 right-4 md:bottom-6 z-30 flex items-center gap-2 rounded-full bg-[color:var(--accent)] text-white px-5 py-3 shadow-lg text-sm font-semibold"
  aria-label={gettext("Ask Tore")}
>
  <.icon name="hero-chat-bubble-left-ellipsis" class="size-5" />
  {gettext("Ask Tore")}
</button>
```

- [ ] Add stub handler in `PlannerLive`:

```elixir
def handle_event("open_chat", _params, socket), do: {:noreply, socket}
```

- [ ] Verify compile.

**Commit:** `jj describe -m "feat: add Ask Tore FAB stub to PlannerLive"`

---

## Task 5 — "Something else" wiring + test

The `handle_event("something_else", ...)` is already included in the `HomeLive` module above (Task 2). This task adds the test coverage.

- [ ] In `home_live_test.exs`, add a describe block:

```elixir
describe "something_else" do
  test "clears tonight slot and shows flash", %{conn: conn, user: user} do
    today = Date.utc_today()
    dow = Date.day_of_week(today)
    week_start = Date.add(today, -(dow - 1))
    plan_id = "plan:#{Date.to_iso8601(week_start)}"
    days = ~w[mon tue wed thu fri sat sun]
    today_key = "#{Enum.at(days, dow - 1)}_dinner"

    {:ok, recipe} =
      Tore.Recipes.create(%{
        title: "Test Meal",
        recipe_type: :meal,
        base_servings: 4,
        prep_time_minutes: 10,
        cook_time_minutes: 30
      })

    # Assign tonight's slot so the button is visible
    Tore.Handlers.PlanningHandler.assign_recipe(plan_id, today_key, recipe.id, 4)

    {:ok, view, _html} = live(conn, ~p"/")
    assert render(view) =~ "Test Meal"

    render_click(view, "something_else")

    html = render(view)
    assert html =~ gettext("Nothing planned for tonight")
    # Flash message
    assert html =~ gettext("Slot cleared")
  end
end
```

- [ ] Run `mix test test/tore_web/live/home_live_test.exs` — all pass.

**Commit:** `jj describe -m "test: something_else event clears tonight slot and shows flash"`

---

## Task 6 — CounterNotes: `build_home_note/1` placeholder + Quantum job

- [ ] Add to `lib/tore/counter_notes.ex`:

```elixir
@doc """
Ensures a home-surface AI commentary note exists for today.
If one already exists (non-expired), does nothing.
Otherwise inserts a static placeholder note valid until end of day.
Phase 4 replaces the static body with a real LLM call.
"""
@spec build_home_note(Date.t()) :: :ok
def build_home_note(date) do
  now = DateTime.utc_now()
  end_of_day =
    date
    |> DateTime.new!(~T[23:59:59], "Etc/UTC")

  existing =
    Repo.one(
      from n in CounterNote,
        where:
          n.surface == "home" and
          n.kind == "habit_pattern" and
          n.status == "pending" and
          (is_nil(n.expires_at) or n.expires_at > ^now),
        limit: 1
    )

  if is_nil(existing) do
    {:ok, _} =
      create(%{
        surface: "home",
        kind: "habit_pattern",
        body: "Ready to cook tonight?",
        expires_at: end_of_day,
        status: "pending"
      })
  end

  :ok
end
```

- [ ] In `config/config.exs` (or wherever Quantum jobs are configured), add a daily job:

```elixir
config :tore, Tore.Scheduler,
  jobs: [
    # ... existing jobs ...
    {"0 6 * * *", {Tore.CounterNotes, :build_home_note, [Date.utc_today()]}}
  ]
```

> **Note:** Quantum evaluates job args at config-load time. If `Date.utc_today()` being static is a problem, wrap in a one-arity function in `Tore.Jobs` that calls `CounterNotes.build_home_note(Date.utc_today())` and reference that instead.

- [ ] Verify compile.

**Commit:** `jj describe -m "feat: CounterNotes.build_home_note/1 placeholder + daily Quantum job"`

---

## Slot struct field note

Before implementing, confirm the shape of a plan slot by running:

```
grep -n "defstruct\|recipe_title\|recipe_id\|skipped" lib/tore/plan_state.ex
```

If `recipe_title` is not on the struct, `slot_title/2` in `HomeLive` must look up recipes from a map. Adjust the mount to also assign:

```elixir
recipes = Recipes.list(sort: :alphabetical)
recipes_by_id = Map.new(recipes, &{&1.id, &1})
```

And update `slot_title/2` to receive `recipes_by_id` and call `Map.get(recipes_by_id, slot.recipe_id)`.

---

## Completion checklist

- [ ] `mix compile --warnings-as-errors` clean
- [ ] `mix test` green (all suites)
- [ ] `/` loads `HomeLive`, `/plan` loads `PlannerLive`
- [ ] Bottom nav shows Home + Week as first two items
- [ ] Tonight card shows recipe title or "Nothing planned"
- [ ] Week strip shows 7 chips with today highlighted
- [ ] FAB visible on both `/` and `/plan`
- [ ] "Something else" clears slot and reloads
- [ ] Counter notes render above tonight card when present
