# Phase 8 — AI-Native UX Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the AI-native UX layer that makes Tore feel genuinely alive — counter notes, week modes, plan health, cooking substitution, kitchen memory UI, contextual command bar, and cook mode — without adding any new pages.

**Architecture:** All primitives are additions to existing LiveViews and the existing handler/LLM stack. New backend modules: `CounterNotes` context (SQLite-backed), `WeekMode` context (SQLite-backed), `PlanHealth` pure-function module (no DB), `Tore.LLM` new callbacks (`suggest_substitution`, `cook_mode_steps`). New UI surfaces are components rendered inline inside existing LiveViews — no new routes except `/memory` (Kitchen Memory settings page).

**Tech Stack:** Elixir/Phoenix/LiveView, SQLite (Ecto), TailwindCSS, OpenRouter (existing LLM adapter at `lib/tore/adapters/open_router.ex`), Mox for LLM mocks in tests.

---

## Scope check

Phase 8 has 8 independent features. They share the new `CounterNotes` context as infrastructure. The dependency order is:

1. **Counter Notes** (Task 1–2) — shared infrastructure, render on home + planner
2. **Plan Health** (Task 3) — pure function, no deps on counter notes
3. **Week Modes** (Task 4) — touches planning handler prompt context
4. **Contextual Command Bar** (Task 5) — uses existing `ChatHandler` (from Phase 4)
5. **Cooking Substitution** (Task 6) — new LLM callback, added to recipe detail
6. **Cook Mode** (Task 7) — new LLM callback, added to recipe detail
7. **Kitchen Memory UI** (Task 8) — reads existing `family_insights` table (from Phase 7)

Tasks 3–8 are independent of each other. Task 2 depends on Task 1.

---

## File map

| File | Action | Responsibility |
|---|---|---|
| `priv/repo/migrations/20260528000020_create_counter_notes.exs` | Create | `counter_notes` table |
| `priv/repo/migrations/20260528000021_create_week_modes.exs` | Create | `week_modes` table |
| `lib/tore/counter_notes/counter_note.ex` | Create | CounterNote Ecto schema |
| `lib/tore/counter_notes.ex` | Create | CounterNotes context — list, create, accept, ignore, expire |
| `lib/tore/week_mode.ex` | Create | WeekMode schema + context + prompt fragment |
| `lib/tore/plan_health.ex` | Create | Pure function: derive plan status from event store state |
| `lib/tore/llm.ex` | Modify | Add `suggest_substitution/2` and `cook_mode_steps/1` callbacks |
| `lib/tore/adapters/open_router.ex` | Modify | Implement both new callbacks |
| `lib/tore/handlers/planning_handler.ex` | Modify | Inject week mode fragment into `build_plan_context/4` |
| `lib/tore_web/live/planner_live.ex` | Modify | Add command bar, plan health badge, counter notes, week mode selector |
| `lib/tore_web/live/recipe_live.ex` | Modify | Add substitution + cook mode UI inline in recipe detail |
| `lib/tore_web/live/settings_live.ex` | Modify | Add Kitchen Memory tab showing `family_insights` with keep/forget |
| `test/tore/counter_notes_test.exs` | Create | CounterNotes context tests |
| `test/tore/week_mode_test.exs` | Create | WeekMode context tests |
| `test/tore/plan_health_test.exs` | Create | PlanHealth pure function tests |
| `test/tore/adapters/open_router_substitution_test.exs` | Create | LLM substitution callback test (Mox) |

---

## Task 1: Counter Notes — migration, schema, context

**Files:**
- Create: `priv/repo/migrations/20260528000020_create_counter_notes.exs`
- Create: `lib/tore/counter_notes/counter_note.ex`
- Create: `lib/tore/counter_notes.ex`
- Test: `test/tore/counter_notes_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/counter_notes_test.exs
defmodule Tore.CounterNotesTest do
  use Tore.DataCase, async: true
  alias Tore.{CounterNotes, Family}

  setup do
    {:ok, _} = Family.create_family(%{name: "Rydholm", locale: "sv"})
    :ok
  end

  test "list_for_surface/1 returns pending notes for the given surface only" do
    {:ok, _} = CounterNotes.create(%{
      surface: "home", kind: "deal_opportunity",
      title: "Chicken deal", body: "ICA has chicken thighs 20% off."
    })
    {:ok, _} = CounterNotes.create(%{
      surface: "pantry", kind: "pantry_assumption",
      title: "Rice", body: "Probably have rice."
    })

    home_notes = CounterNotes.list_for_surface("home")
    assert length(home_notes) == 1
    assert hd(home_notes).surface == "home"
  end

  test "ignore/1 removes note from surface listing" do
    {:ok, note} = CounterNotes.create(%{
      surface: "home", kind: "deal_opportunity",
      title: "Test", body: "Test."
    })
    {:ok, _} = CounterNotes.ignore(note.id)
    assert CounterNotes.list_for_surface("home") == []
  end

  test "accept/1 sets status to accepted" do
    {:ok, note} = CounterNotes.create(%{
      surface: "home", kind: "habit_pattern",
      title: "Thursday", body: "You often skip Thursday."
    })
    {:ok, updated} = CounterNotes.accept(note.id)
    assert updated.status == "accepted"
  end

  test "expire_stale/0 marks expired notes" do
    past = DateTime.add(DateTime.utc_now(), -3600, :second)
    {:ok, note} = CounterNotes.create(%{
      surface: "week", kind: "plan_repair",
      title: "Fragile", body: "Week looks fragile.",
      expires_at: past
    })
    {count, _} = CounterNotes.expire_stale()
    assert count == 1
    assert CounterNotes.list_for_surface("week") == []
  end
end
```

- [ ] **Step 2: Run test — expect failure (no module yet)**

```bash
mix test test/tore/counter_notes_test.exs
```

Expected: `(UndefinedFunctionError)` — `Tore.CounterNotes` not found.

- [ ] **Step 3: Write the migration**

```elixir
# priv/repo/migrations/20260528000020_create_counter_notes.exs
defmodule Tore.Repo.Migrations.CreateCounterNotes do
  use Ecto.Migration

  def change do
    create table(:counter_notes) do
      add :family_id, references(:families, on_delete: :delete_all), null: false
      add :surface, :string, null: false
      add :kind, :string, null: false
      add :title, :string, null: false
      add :body, :text, null: false
      add :commands, :text
      add :confidence, :string, null: false, default: "medium"
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime
      timestamps(updated_at: false)
    end

    create index(:counter_notes, [:family_id, :surface, :status])
  end
end
```

- [ ] **Step 4: Write the schema**

```elixir
# lib/tore/counter_notes/counter_note.ex
defmodule Tore.CounterNotes.CounterNote do
  use Ecto.Schema
  import Ecto.Changeset

  schema "counter_notes" do
    field :surface, :string
    field :kind, :string
    field :title, :string
    field :body, :string
    field :commands, :string
    field :confidence, :string, default: "medium"
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime
    belongs_to :family, Tore.Family.FamilySchema
    timestamps(updated_at: false)
  end

  @valid_surfaces ~w(home week groceries pantry deals)
  @valid_kinds ~w(deal_opportunity plan_repair pantry_assumption habit_pattern)
  @valid_confidences ~w(low medium high)
  @valid_statuses ~w(pending accepted ignored expired)

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:surface, :kind, :title, :body, :commands,
                    :confidence, :status, :expires_at, :family_id])
    |> validate_required([:surface, :kind, :title, :body, :family_id])
    |> validate_inclusion(:surface, @valid_surfaces)
    |> validate_inclusion(:kind, @valid_kinds)
    |> validate_inclusion(:confidence, @valid_confidences)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
```

- [ ] **Step 5: Write the CounterNotes context**

```elixir
# lib/tore/counter_notes.ex
defmodule Tore.CounterNotes do
  import Ecto.Query
  alias Tore.{Repo, CounterNotes.CounterNote, Family}

  @spec list_for_surface(String.t()) :: [CounterNote.t()]
  def list_for_surface(surface) do
    family_id = Family.get_family!().id
    now = DateTime.utc_now()

    Repo.all(
      from n in CounterNote,
        where:
          n.family_id == ^family_id and
          n.surface == ^surface and
          n.status == "pending" and
          (is_nil(n.expires_at) or n.expires_at > ^now),
        order_by: [asc: n.inserted_at],
        limit: 3
    )
  end

  @spec create(map()) :: {:ok, CounterNote.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    family_id = Family.get_family!().id
    %CounterNote{}
    |> CounterNote.changeset(Map.put(attrs, :family_id, family_id))
    |> Repo.insert()
  end

  @spec accept(integer()) :: {:ok, CounterNote.t()} | {:error, Ecto.Changeset.t()}
  def accept(id) do
    note = Repo.get_by!(CounterNote, id: id, family_id: Family.get_family!().id)
    note |> CounterNote.changeset(%{status: "accepted"}) |> Repo.update()
  end

  @spec ignore(integer()) :: {:ok, CounterNote.t()} | {:error, Ecto.Changeset.t()}
  def ignore(id) do
    note = Repo.get_by!(CounterNote, id: id, family_id: Family.get_family!().id)
    note |> CounterNote.changeset(%{status: "ignored"}) |> Repo.update()
  end

  @spec expire_stale() :: {integer(), nil}
  def expire_stale do
    now = DateTime.utc_now()
    Repo.update_all(
      from(n in CounterNote,
        where: n.status == "pending" and not is_nil(n.expires_at) and n.expires_at <= ^now),
      set: [status: "expired"]
    )
  end
end
```

- [ ] **Step 6: Run migration and tests**

```bash
mix ecto.migrate && mix test test/tore/counter_notes_test.exs
```

Expected: 4 tests pass.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(counter-notes): migration, schema, and context — list/create/accept/ignore/expire"
```

---

## Task 2: Render counter notes on home screen and planner

Counter notes appear inline on the home screen (below the week strip) and the planner/week view (below the week grid). The UI renders `pending` notes for the current surface, with Accept and Ignore buttons.

**Files:**
- Modify: `lib/tore_web/live/planner_live.ex`

The home screen LiveView (`HomeLive`) is being built in Phase 3 and doesn't exist yet in the current codebase. For now, add counter note rendering to `PlannerLive` — it is the current `/` route and will be the week view going forward.

- [ ] **Step 1: Load counter notes in PlannerLive mount**

In `lib/tore_web/live/planner_live.ex`, add to the bottom of the `mount/3` assigns:

```elixir
# In the {:ok, assign(socket, ...)} call in mount/3, add:
counter_notes: Tore.CounterNotes.list_for_surface("week")
```

The full updated mount assigns block:

```elixir
{:ok,
 assign(socket,
   today: today,
   week_start: week_start,
   plan_id: plan_id,
   plan_state: plan_state,
   recipes: recipes,
   slot_action: nil,
   counter_notes: Tore.CounterNotes.list_for_surface("week")
 )}
```

- [ ] **Step 2: Add event handlers for note accept/ignore**

Add two new `handle_event` clauses anywhere in `lib/tore_web/live/planner_live.ex`:

```elixir
def handle_event("accept_note", %{"id" => id}, socket) do
  Tore.CounterNotes.accept(String.to_integer(id))
  {:noreply, assign(socket, counter_notes: Tore.CounterNotes.list_for_surface("week"))}
end

def handle_event("ignore_note", %{"id" => id}, socket) do
  Tore.CounterNotes.ignore(String.to_integer(id))
  {:noreply, assign(socket, counter_notes: Tore.CounterNotes.list_for_surface("week"))}
end
```

- [ ] **Step 3: Render counter notes in the planner template**

Open `lib/tore_web/live/planner_live.html.heex`. Locate the top of the template and add the counter notes section as the first thing inside the page container:

```heex
<%!-- Counter notes — ambient AI suggestions for this surface --%>
<%= if @counter_notes != [] do %>
  <div class="flex flex-col gap-3 mb-4">
    <%= for note <- @counter_notes do %>
      <div class="rounded-2xl border border-[color:var(--hairline)] bg-[color:var(--surface-raised)] p-4">
        <p class="text-[10px] font-semibold text-[color:var(--accent)] uppercase tracking-widest mb-1">
          {gettext("Tore noticed")}
        </p>
        <p class="font-semibold text-[var(--text)] text-sm mb-0.5">{note.title}</p>
        <p class="text-sm text-[color:var(--muted)] mb-3">{note.body}</p>
        <div class="flex gap-2">
          <button phx-click="accept_note" phx-value-id={note.id}
            class="flex-1 py-2 rounded-xl bg-[color:var(--accent)] text-white text-xs font-semibold">
            {gettext("Accept")}
          </button>
          <button phx-click="ignore_note" phx-value-id={note.id}
            class="px-4 py-2 rounded-xl border border-[color:var(--hairline)] text-[color:var(--muted)] text-xs font-medium">
            {gettext("Ignore")}
          </button>
        </div>
      </div>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 4: Start the server and manually verify**

```bash
mix phx.server
```

In another terminal, seed a test note:

```bash
mix run --no-halt -e '
  {:ok, _} = Tore.CounterNotes.create(%{
    surface: "week",
    kind: "plan_repair",
    title: "Wednesday looks fragile",
    body: "Wednesday depends on Sunday prep, but Sunday has no prep block."
  })
'
```

Open http://localhost:4000. Verify the note appears at the top of the planner. Click Ignore — verify it disappears immediately.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(counter-notes): render ambient notes on planner with accept/ignore"
```

---

## Task 3: Plan Health — derived status indicator

`PlanHealth` is a pure function module — no DB, no LLM. It computes a status tuple from the current `Planning.State`. It's shown as a small badge on the planner.

**Files:**
- Create: `lib/tore/plan_health.ex`
- Modify: `lib/tore_web/live/planner_live.ex`
- Test: `test/tore/plan_health_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/plan_health_test.exs
defmodule Tore.PlanHealthTest do
  use ExUnit.Case, async: true
  alias Tore.PlanHealth

  defp make_state(assigned_days) do
    slots =
      assigned_days
      |> Enum.map(fn day -> {"#{day}_dinner", %{recipe_id: 1, skipped: false}} end)
      |> Map.new()
    %{slots: slots}
  end

  test "returns :unplanned when no slots assigned" do
    {status, msg} = PlanHealth.compute(%{slots: %{}})
    assert status == :unplanned
    assert is_binary(msg)
  end

  test "returns :ready when all 5 weekday slots have recipes" do
    state = make_state(~w(mon tue wed thu fri))
    {status, _} = PlanHealth.compute(state)
    assert status == :ready
  end

  test "returns :flexible when some weekday slots are unplanned" do
    state = make_state(~w(mon tue))
    {status, msg} = PlanHealth.compute(state)
    assert status == :flexible
    assert String.contains?(msg, "3")
  end

  test "returns :fragile when a slot is skipped" do
    slots = %{
      "mon_dinner" => %{recipe_id: 1, skipped: false},
      "tue_dinner" => %{recipe_id: nil, skipped: true},
      "wed_dinner" => %{recipe_id: 2, skipped: false},
      "thu_dinner" => %{recipe_id: 3, skipped: false},
      "fri_dinner" => %{recipe_id: 4, skipped: false}
    }
    {status, _} = PlanHealth.compute(%{slots: slots})
    assert status == :fragile
  end
end
```

- [ ] **Step 2: Run the test — expect failure**

```bash
mix test test/tore/plan_health_test.exs
```

Expected: `(UndefinedFunctionError)` — `Tore.PlanHealth` not found.

- [ ] **Step 3: Write PlanHealth**

```elixir
# lib/tore/plan_health.ex
defmodule Tore.PlanHealth do
  @type status :: :ready | :flexible | :fragile | :unplanned
  @type result :: {status(), String.t()}

  @weekdays ~w(mon tue wed thu fri)

  @spec compute(map()) :: result()
  def compute(plan_state) do
    slots = plan_state.slots || %{}
    week_keys = Enum.map(@weekdays, &"#{&1}_dinner")

    assigned = Enum.filter(week_keys, fn k ->
      slot = Map.get(slots, k)
      slot && slot.recipe_id && !slot.skipped
    end)

    skipped = Enum.filter(week_keys, fn k ->
      slot = Map.get(slots, k)
      slot && slot.skipped
    end)

    unplanned_count = length(week_keys) - length(assigned) - length(skipped)

    cond do
      length(assigned) == 0 and length(skipped) == 0 ->
        {:unplanned, "No plan for this week yet."}

      length(skipped) > 0 ->
        {:fragile, "#{length(skipped)} slot(s) skipped — plan may need repair."}

      unplanned_count > 0 ->
        {:flexible, "#{unplanned_count} slot(s) unplanned."}

      true ->
        {:ready, "Plan looks good for the week."}
    end
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
mix test test/tore/plan_health_test.exs
```

Expected: 4 tests pass.

- [ ] **Step 5: Add plan health to PlannerLive**

In `lib/tore_web/live/planner_live.ex`, add to the mount assigns:

```elixir
plan_health: Tore.PlanHealth.compute(plan_state)
```

In `handle_info({:events, _events}, socket)` (the PubSub handler), add:

```elixir
plan_health: Tore.PlanHealth.compute(plan_state)
```

If no PubSub handler exists, find where `plan_state` is refreshed on PubSub and add `plan_health` there. If `handle_info` for plan events doesn't exist in `planner_live.ex`, add it:

```elixir
def handle_info({:events, _events}, socket) do
  {:ok, plan_state} = Tore.Handlers.PlanningHandler.load_plan(socket.assigns.plan_id)
  {:noreply, assign(socket,
    plan_state: plan_state,
    plan_health: Tore.PlanHealth.compute(plan_state)
  )}
end
```

- [ ] **Step 6: Render plan health badge in planner template**

In `lib/tore_web/live/planner_live.html.heex`, add after the week navigation controls and before the day grid:

```heex
<%!-- Plan health badge --%>
<div class={[
  "inline-flex items-center gap-1.5 text-xs font-semibold px-3 py-1.5 rounded-full mb-4",
  elem(@plan_health, 0) == :ready && "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400",
  elem(@plan_health, 0) == :flexible && "bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400",
  elem(@plan_health, 0) == :fragile && "bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400",
  elem(@plan_health, 0) == :unplanned && "bg-[color:var(--surface-raised)] text-[color:var(--muted)]"
]}>
  <span class="size-1.5 rounded-full inline-block" style={health_dot_color(elem(@plan_health, 0))} />
  {elem(@plan_health, 1)}
</div>
```

Add the helper function to `planner_live.ex`:

```elixir
defp health_dot_color(:ready), do: "background:#16a34a"
defp health_dot_color(:flexible), do: "background:#ca8a04"
defp health_dot_color(:fragile), do: "background:#ea580c"
defp health_dot_color(:unplanned), do: "background:var(--muted)"
```

- [ ] **Step 7: Start server and verify badge**

```bash
mix phx.server
```

Open http://localhost:4000. Verify the badge appears below the nav controls. Assign some meals and confirm the badge updates live.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(plan-health): derive plan status badge from event store state"
```

---

## Task 4: Week Modes — temporary planning biases

`WeekMode` stores the current week's mode in SQLite (one row per family per week). It is injected as a prompt fragment into the planning handler. The UI shows a mode selector on the planner.

**Files:**
- Create: `priv/repo/migrations/20260528000021_create_week_modes.exs`
- Create: `lib/tore/week_mode.ex`
- Modify: `lib/tore/handlers/planning_handler.ex`
- Modify: `lib/tore_web/live/planner_live.ex`
- Test: `test/tore/week_mode_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/tore/week_mode_test.exs
defmodule Tore.WeekModeTest do
  use Tore.DataCase, async: true
  alias Tore.{WeekMode, Family}

  setup do
    {:ok, _} = Family.create_family(%{name: "Rydholm", locale: "sv"})
    :ok
  end

  test "get_current_mode/0 returns 'normal' when nothing set" do
    assert WeekMode.get_current_mode() == "normal"
  end

  test "set_mode/1 and get_current_mode/0 round-trip" do
    {:ok, _} = WeekMode.set_mode("low_effort")
    assert WeekMode.get_current_mode() == "low_effort"
  end

  test "set_mode/1 twice overwrites — only one record per week" do
    {:ok, _} = WeekMode.set_mode("low_effort")
    {:ok, _} = WeekMode.set_mode("budget_week")
    assert WeekMode.get_current_mode() == "budget_week"
  end

  test "set_mode/1 with invalid mode returns error" do
    assert {:error, changeset} = WeekMode.set_mode("turbo_cook")
    assert changeset.errors[:mode]
  end

  test "mode_prompt_fragment/1 returns nil for normal" do
    assert WeekMode.mode_prompt_fragment("normal") == nil
  end

  test "mode_prompt_fragment/1 returns non-nil string for low_effort" do
    fragment = WeekMode.mode_prompt_fragment("low_effort")
    assert is_binary(fragment)
    assert String.contains?(fragment, "Low effort")
  end
end
```

- [ ] **Step 2: Run the test — expect failure**

```bash
mix test test/tore/week_mode_test.exs
```

Expected: `(UndefinedFunctionError)` — `Tore.WeekMode` not found.

- [ ] **Step 3: Write the migration**

```elixir
# priv/repo/migrations/20260528000021_create_week_modes.exs
defmodule Tore.Repo.Migrations.CreateWeekModes do
  use Ecto.Migration

  def change do
    create table(:week_modes) do
      add :family_id, references(:families, on_delete: :delete_all), null: false
      add :mode, :string, null: false, default: "normal"
      add :week_start, :date, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:week_modes, [:family_id, :week_start])
  end
end
```

- [ ] **Step 4: Write the WeekMode schema and context**

```elixir
# lib/tore/week_mode.ex
defmodule Tore.WeekMode do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Tore.{Repo, Family}

  @valid_modes ~w(normal low_effort budget_week use_pantry more_leftovers
                  high_protein freezer_week guest_week)

  schema "week_modes" do
    field :mode, :string, default: "normal"
    field :week_start, :date
    belongs_to :family, Tore.Family.FamilySchema
    timestamps(updated_at: false)
  end

  def changeset(wm, attrs) do
    wm
    |> cast(attrs, [:mode, :week_start, :family_id])
    |> validate_required([:mode, :week_start, :family_id])
    |> validate_inclusion(:mode, @valid_modes)
  end

  @spec get_current_mode() :: String.t()
  def get_current_mode do
    family_id = Family.get_family!().id
    week_start = current_week_start()

    case Repo.one(
           from wm in __MODULE__,
             where: wm.family_id == ^family_id and wm.week_start == ^week_start
         ) do
      nil -> "normal"
      wm -> wm.mode
    end
  end

  @spec set_mode(String.t()) :: {:ok, __MODULE__.t()} | {:error, Ecto.Changeset.t()}
  def set_mode(mode) do
    family_id = Family.get_family!().id
    week_start = current_week_start()
    attrs = %{mode: mode, week_start: week_start, family_id: family_id}

    existing =
      Repo.one(
        from wm in __MODULE__,
          where: wm.family_id == ^family_id and wm.week_start == ^week_start
      )

    (existing || %__MODULE__{})
    |> changeset(attrs)
    |> Repo.insert_or_update()
  end

  @spec mode_prompt_fragment(String.t()) :: String.t() | nil
  def mode_prompt_fragment("normal"), do: nil

  def mode_prompt_fragment("low_effort") do
    "Current week mode: Low effort. Prefer meals with total time ≤30 minutes. " <>
      "Fewer unique cooking sessions. More leftovers where possible. Do not change pinned slots."
  end

  def mode_prompt_fragment("budget_week") do
    "Current week mode: Budget week. Prioritise meals using on-sale ingredients and pantry staples. " <>
      "Minimise unique grocery items."
  end

  def mode_prompt_fragment("use_pantry") do
    "Current week mode: Use pantry. Prioritise meals that use existing pantry inventory. " <>
      "Avoid requiring new ingredients where possible."
  end

  def mode_prompt_fragment("more_leftovers") do
    "Current week mode: More leftovers. Prefer recipes that produce extra servings. " <>
      "Plan for intentional leftover meals later in the week."
  end

  def mode_prompt_fragment("high_protein") do
    "Current week mode: High protein. Prefer meals high in protein. " <>
      "Increase meat, fish, and legume proportion."
  end

  def mode_prompt_fragment("freezer_week") do
    "Current week mode: Freezer week. Prioritise using frozen ingredients. " <>
      "Suggest meals compatible with freezer staples."
  end

  def mode_prompt_fragment("guest_week") do
    "Current week mode: Guest week. Plan for larger portions and more impressive recipes suitable for guests."
  end

  def mode_prompt_fragment(_), do: nil

  defp current_week_start do
    today = Date.utc_today()
    Date.add(today, -(Date.day_of_week(today) - 1))
  end
end
```

- [ ] **Step 5: Run tests**

```bash
mix ecto.migrate && mix test test/tore/week_mode_test.exs
```

Expected: 6 tests pass.

- [ ] **Step 6: Inject week mode fragment into planning_handler**

Open `lib/tore/handlers/planning_handler.ex`. Find `build_plan_context/4`. It returns a map passed to `@llm.generate_plan/1`. Add the week mode fragment to that map:

```elixir
# In build_plan_context/4, add to the returned map:
week_mode_fragment: Tore.WeekMode.mode_prompt_fragment(Tore.WeekMode.get_current_mode())
```

The full function currently ends with a map. Add the key so the result looks like:

```elixir
%{
  recipes: ...,
  slot_keys: ...,
  pins: ...,
  pantry: ...,
  deals: ...,
  recent_recipes: ...,
  week_start: ...,
  mode: ...,
  dietary_guidance: ...,
  week_mode_fragment: Tore.WeekMode.mode_prompt_fragment(Tore.WeekMode.get_current_mode())
}
```

- [ ] **Step 7: Inject week mode fragment into the plan prompt**

Open `priv/llm/prompts/plan_weekly.eex`. Find the dietary guidance section. After it, add:

```eex
<%= if assigns[:week_mode_fragment] do %>
<%= @week_mode_fragment %>
<% end %>
```

- [ ] **Step 8: Add week mode selector to PlannerLive**

In `lib/tore_web/live/planner_live.ex`, add to mount assigns:

```elixir
current_week_mode: Tore.WeekMode.get_current_mode()
```

Add event handler:

```elixir
def handle_event("set_week_mode", %{"mode" => mode}, socket) do
  case Tore.WeekMode.set_mode(mode) do
    {:ok, _} ->
      {:noreply, assign(socket, current_week_mode: mode)}
    {:error, _} ->
      {:noreply, socket}
  end
end
```

In `lib/tore_web/live/planner_live.html.heex`, add the mode selector below the plan health badge:

```heex
<%!-- Week mode selector --%>
<div class="flex flex-wrap gap-2 mb-4">
  <%= for mode <- ~w(normal low_effort budget_week use_pantry more_leftovers) do %>
    <button
      phx-click="set_week_mode"
      phx-value-mode={mode}
      class={[
        "px-3 py-1.5 rounded-full text-xs font-medium border transition-colors",
        @current_week_mode == mode &&
          "bg-[color:var(--accent)] text-white border-[color:var(--accent)]",
        @current_week_mode != mode &&
          "bg-transparent text-[color:var(--muted)] border-[color:var(--hairline)] hover:border-[color:var(--accent)] hover:text-[color:var(--accent)]"
      ]}
    >
      {mode_label(mode)}
    </button>
  <% end %>
</div>
```

Add the helper to `planner_live.ex`:

```elixir
defp mode_label("normal"), do: gettext("Normal")
defp mode_label("low_effort"), do: gettext("Low effort")
defp mode_label("budget_week"), do: gettext("Budget")
defp mode_label("use_pantry"), do: gettext("Use pantry")
defp mode_label("more_leftovers"), do: gettext("More leftovers")
defp mode_label(m), do: m
```

- [ ] **Step 9: Start server and verify**

```bash
mix phx.server
```

Open http://localhost:4000. Verify mode buttons render. Tap "Low effort" — confirm button becomes highlighted. Tap "Normal" — resets. Check that the mode is persisted between page refreshes.

- [ ] **Step 10: Commit**

```bash
jj describe -m "feat(week-modes): temporary planning biases per week, injected into plan prompt"
```

---

## Task 5: Contextual Command Bar on planner

A one-line NL input at the top of the planner routes commands through the existing `ChatHandler`. Requires Phase 4's `ChatHandler` and `SystemPrompt` modules. If those don't exist yet, this task must wait until Phase 4 is complete.

**Files:**
- Modify: `lib/tore_web/live/planner_live.ex`
- Modify: `lib/tore_web/live/planner_live.html.heex`

- [ ] **Step 1: Add command bar assigns to PlannerLive**

In `lib/tore_web/live/planner_live.ex`, add to mount assigns:

```elixir
quick_reply: nil,
quick_loading: false
```

- [ ] **Step 2: Add event handlers**

```elixir
def handle_event("quick_command", %{"command" => command}, socket) when command != "" do
  socket = assign(socket, quick_loading: true, quick_reply: nil)
  send(self(), {:run_quick_command, command})
  {:noreply, socket}
end

def handle_event("quick_command", %{"command" => ""}, socket) do
  {:noreply, socket}
end

def handle_event("dismiss_quick_reply", _params, socket) do
  {:noreply, assign(socket, quick_reply: nil)}
end

def handle_info({:run_quick_command, command}, socket) do
  system_prompt = Tore.Chat.SystemPrompt.build()
  reply =
    case Tore.Handlers.ChatHandler.handle_text(command, %{system_prompt: system_prompt}) do
      {:ok, text, _action} -> text
      {:error, _} -> gettext("Something went wrong — please try again.")
    end
  {:noreply, assign(socket, quick_reply: reply, quick_loading: false)}
end
```

- [ ] **Step 3: Add command bar to template**

In `lib/tore_web/live/planner_live.html.heex`, add at the very top of the page content (before counter notes):

```heex
<%!-- Contextual command bar --%>
<form phx-submit="quick_command" class="mb-4">
  <div class="relative">
    <input
      type="text"
      name="command"
      placeholder={gettext("Tell Tore what to change… (e.g. no fish this week)")}
      autocomplete="off"
      class="w-full rounded-2xl border border-[color:var(--hairline)] bg-[color:var(--surface)] pl-4 pr-12 py-3 text-sm text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)]"
    />
    <button type="submit"
      class="absolute right-2 top-1/2 -translate-y-1/2 size-8 rounded-xl bg-[color:var(--accent)] text-white flex items-center justify-center">
      <.icon name="hero-arrow-up" class="size-4" />
    </button>
  </div>
</form>

<%= if @quick_loading do %>
  <div class="rounded-xl bg-[color:var(--surface-raised)] px-4 py-3 text-sm text-[color:var(--muted)] mb-4">
    {gettext("Thinking…")}
  </div>
<% end %>

<%= if @quick_reply do %>
  <div class="rounded-xl bg-[color:var(--surface-raised)] px-4 py-3 text-sm text-[var(--text)] mb-4 flex items-start justify-between gap-2">
    <span>{@quick_reply}</span>
    <button phx-click="dismiss_quick_reply" class="text-[color:var(--muted)] shrink-0 mt-0.5">
      <.icon name="hero-x-mark" class="size-4" />
    </button>
  </div>
<% end %>
```

- [ ] **Step 4: Start server and verify**

```bash
mix phx.server
```

Open http://localhost:4000. Type "skip Thursday dinner" into the command bar. Verify the assistant message appears inline. Verify the plan actually updates (Thursday slot shows skipped).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(planner): contextual NL command bar routing through ChatHandler"
```

---

## Task 6: Cooking Substitution — "Missing something?"

Adds a collapsible "Missing something?" section to the recipe detail view. The user types what they're missing; a new LLM callback returns a substitution and optionally updated steps.

**Files:**
- Modify: `lib/tore/llm.ex`
- Modify: `lib/tore/adapters/open_router.ex`
- Modify: `lib/tore_web/live/recipe_live.ex`
- Test: `test/tore/adapters/open_router_substitution_test.exs`

- [ ] **Step 1: Add `suggest_substitution/2` callback to LLM behaviour**

In `lib/tore/llm.ex`, add:

```elixir
@callback suggest_substitution(missing :: String.t(), recipe_context :: String.t()) ::
  {:ok, %{suggestion: String.t(), updated_steps: String.t() | nil}} | {:error, term()}
```

- [ ] **Step 2: Write a Mox test for the callback**

```elixir
# test/tore/adapters/open_router_substitution_test.exs
defmodule Tore.Adapters.OpenRouterSubstitutionTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!

  test "suggest_substitution mock returns suggestion map" do
    Tore.LLMMock
    |> expect(:suggest_substitution, fn "crème fraîche", _recipe ->
      {:ok, %{suggestion: "Use Greek yogurt + a little lemon.", updated_steps: nil}}
    end)

    assert {:ok, %{suggestion: suggestion}} =
             Tore.LLMMock.suggest_substitution("crème fraîche", "Salmon with sauce")

    assert String.contains?(suggestion, "yogurt")
  end
end
```

- [ ] **Step 3: Run the test — expect failure (callback not in mock)**

```bash
mix test test/tore/adapters/open_router_substitution_test.exs
```

Expected: error about missing callback on mock.

- [ ] **Step 4: Add `suggest_substitution` to the test mock**

Find where `Mox.defmock` is defined for the LLM. This is typically in `test/support/mocks.ex` or `test/test_helper.exs`. Check:

```bash
grep -rn "defmock\|LLMMock" test/
```

Add `:suggest_substitution` to the list of callbacks if it isn't auto-derived. With Mox and `@behaviour`, all callbacks are automatically mockable once defined in the behaviour. Re-run the test — it should pass once the behaviour defines the callback.

- [ ] **Step 5: Implement `suggest_substitution/2` in OpenRouter adapter**

In `lib/tore/adapters/open_router.ex`, add:

```elixir
@impl Tore.LLM
def suggest_substitution(missing, recipe_context) do
  system = """
  You are a practical cooking assistant. The user is missing an ingredient mid-cook.
  Suggest a realistic substitution they can make right now with common kitchen items.
  If the substitution requires changing the steps, include brief updated instructions.
  Return JSON only: {"suggestion": "...", "updated_steps": "..." or null}
  Keep the suggestion to 1-2 sentences. Be direct and practical.
  """

  user = "Recipe: #{recipe_context}\nMissing ingredient: #{missing}"

  case chat(system, user) do
    {:ok, %{"suggestion" => suggestion} = result, _usage} ->
      {:ok, %{
        suggestion: suggestion,
        updated_steps: result["updated_steps"]
      }}
    {:ok, _, _} ->
      {:error, :invalid_response}
    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] **Step 6: Add substitution UI to RecipeLive**

The recipe detail in `RecipeLive` is rendered when `@selected` is set. Open `lib/tore_web/live/recipe_live.ex`.

Add to mount assigns:

```elixir
show_substitution: false,
substitution: nil,
substitution_loading: false
```

Add event handlers:

```elixir
def handle_event("toggle_substitution", _params, socket) do
  {:noreply, assign(socket, show_substitution: !socket.assigns.show_substitution, substitution: nil)}
end

def handle_event("get_substitution", %{"missing" => missing}, socket) when missing != "" do
  recipe_title = socket.assigns.selected && socket.assigns.selected.title || "current recipe"
  socket = assign(socket, substitution_loading: true)
  send(self(), {:run_substitution, missing, recipe_title})
  {:noreply, socket}
end

def handle_event("get_substitution", %{"missing" => ""}, socket) do
  {:noreply, socket}
end

def handle_info({:run_substitution, missing, recipe_context}, socket) do
  llm = Application.get_env(:tore, :llm_client)

  result =
    case llm.suggest_substitution(missing, recipe_context) do
      {:ok, r} -> r
      {:error, _} -> %{suggestion: gettext("Couldn't find a substitution — try a web search."), updated_steps: nil}
    end

  {:noreply, assign(socket, substitution: result, substitution_loading: false)}
end
```

- [ ] **Step 7: Add substitution panel to the recipe detail template**

Find where the recipe detail is rendered in `lib/tore_web/live/recipe_live.html.heex`. It shows when `@selected` is set. At the bottom of the detail section, after instructions, add:

```heex
<%!-- Cooking substitution --%>
<div class="mt-6 pt-4 border-t border-[color:var(--hairline)]">
  <button phx-click="toggle_substitution"
    class="flex items-center gap-2 text-sm text-[color:var(--muted)] hover:text-[var(--text)] transition-colors">
    <.icon name="hero-question-mark-circle" class="size-4" />
    {gettext("Missing something?")}
  </button>

  <%= if @show_substitution do %>
    <form phx-submit="get_substitution" class="mt-3 flex gap-2">
      <input
        type="text"
        name="missing"
        placeholder={gettext("e.g. crème fraîche")}
        autocomplete="off"
        class="flex-1 rounded-xl border border-[color:var(--hairline)] bg-[color:var(--surface)] px-3 py-2.5 text-sm text-[var(--text)] placeholder:text-[color:var(--muted)] focus:outline-none focus:ring-2 focus:ring-[color:var(--accent)]"
      />
      <button type="submit"
        class="bg-[color:var(--accent)] text-white rounded-xl px-4 py-2.5 text-sm font-semibold">
        {gettext("Ask")}
      </button>
    </form>

    <%= if @substitution_loading do %>
      <p class="mt-3 text-sm text-[color:var(--muted)]">{gettext("Thinking…")}</p>
    <% end %>

    <%= if @substitution do %>
      <div class="mt-3 rounded-2xl bg-[color:var(--surface-raised)] p-4">
        <p class="text-sm text-[var(--text)] leading-relaxed">{@substitution.suggestion}</p>
        <%= if @substitution.updated_steps do %>
          <p class="mt-2 text-sm text-[color:var(--muted)] leading-relaxed">{@substitution.updated_steps}</p>
        <% end %>
      </div>
    <% end %>
  <% end %>
</div>
```

- [ ] **Step 8: Start server and verify**

```bash
mix phx.server
```

Open http://localhost:4000/recipes. Open any recipe detail. Click "Missing something?". Type "crème fraîche". Verify a substitution appears below. Verify toggling the section collapses it.

- [ ] **Step 9: Commit**

```bash
jj describe -m "feat(substitution): missing ingredient substitution on recipe detail"
```

---

## Task 7: Cook Mode — compressed action-oriented recipe view

Adds a "Cook mode" toggle on the recipe detail that compresses the recipe into action-oriented phases (Do first / While it cooks / Finish). A "Make it faster" option rewrites steps with shortcuts.

**Files:**
- Modify: `lib/tore/llm.ex`
- Modify: `lib/tore/adapters/open_router.ex`
- Modify: `lib/tore_web/live/recipe_live.ex`

- [ ] **Step 1: Add `cook_mode_steps/1` callback to LLM behaviour**

In `lib/tore/llm.ex`, add:

```elixir
@callback cook_mode_steps(recipe :: map()) ::
  {:ok, %{do_first: [String.t()], while_cooking: [String.t()], finish: [String.t()]}} |
  {:error, term()}
```

- [ ] **Step 2: Implement `cook_mode_steps/1` in OpenRouter adapter**

In `lib/tore/adapters/open_router.ex`, add:

```elixir
@impl Tore.LLM
def cook_mode_steps(recipe) do
  system = """
  You are a cooking assistant. Compress recipe steps into a 3-phase action list.
  Phase 1 "do_first": things to start before anything else (pre-heat, prep, start slow things).
  Phase 2 "while_cooking": things to do while the main component cooks.
  Phase 3 "finish": final assembly and plating.
  Each phase is a list of short action phrases (5-10 words each). Max 4 items per phase.
  Return JSON only: {"do_first": [...], "while_cooking": [...], "finish": [...]}
  """

  user = """
  Recipe: #{recipe["title"] || recipe[:title] || "Unknown"}
  Steps: #{recipe["instructions"] || recipe[:instructions] || "No instructions"}
  """

  case chat(system, user) do
    {:ok, %{"do_first" => do_first, "while_cooking" => while_cooking, "finish" => finish}, _usage} ->
      {:ok, %{do_first: do_first, while_cooking: while_cooking, finish: finish}}
    {:ok, _, _} ->
      {:error, :invalid_response}
    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] **Step 3: Add cook mode state to RecipeLive**

In `lib/tore_web/live/recipe_live.ex`, add to mount assigns:

```elixir
cook_mode: false,
cook_mode_steps: nil,
cook_mode_loading: false
```

Add event handlers:

```elixir
def handle_event("enter_cook_mode", _params, socket) do
  recipe = socket.assigns.selected
  socket = assign(socket, cook_mode: true, cook_mode_loading: true, cook_mode_steps: nil)
  send(self(), {:load_cook_mode, recipe})
  {:noreply, socket}
end

def handle_event("exit_cook_mode", _params, socket) do
  {:noreply, assign(socket, cook_mode: false, cook_mode_steps: nil)}
end

def handle_info({:load_cook_mode, recipe}, socket) do
  llm = Application.get_env(:tore, :llm_client)

  steps =
    case llm.cook_mode_steps(Map.from_struct(recipe)) do
      {:ok, s} -> s
      {:error, _} -> %{
        do_first: [gettext("Follow the recipe steps")],
        while_cooking: [],
        finish: [gettext("Plate and serve")]
      }
    end

  {:noreply, assign(socket, cook_mode_steps: steps, cook_mode_loading: false)}
end
```

- [ ] **Step 4: Add cook mode panel to recipe detail template**

In `lib/tore_web/live/recipe_live.html.heex`, in the recipe detail section, add a "Cook mode" button next to the recipe title or action buttons:

```heex
<%!-- Cook mode toggle --%>
<%= if !@cook_mode do %>
  <button phx-click="enter_cook_mode"
    class="mt-4 w-full py-3 rounded-2xl bg-[color:var(--accent)] text-white text-sm font-semibold flex items-center justify-center gap-2">
    <.icon name="hero-fire" class="size-4" />
    {gettext("Start cooking")}
  </button>
<% else %>
  <div class="mt-4 rounded-2xl bg-[color:var(--surface-raised)] p-4">
    <div class="flex items-center justify-between mb-4">
      <h3 class="font-semibold text-[var(--text)]">{gettext("Cook mode")}</h3>
      <button phx-click="exit_cook_mode" class="text-[color:var(--muted)] text-sm">
        {gettext("Exit")}
      </button>
    </div>

    <%= if @cook_mode_loading do %>
      <p class="text-sm text-[color:var(--muted)]">{gettext("Preparing steps…")}</p>
    <% end %>

    <%= if @cook_mode_steps do %>
      <div class="space-y-4">
        <div>
          <p class="text-xs font-semibold text-[color:var(--accent)] uppercase tracking-wide mb-2">
            {gettext("Do first")}
          </p>
          <ul class="space-y-1">
            <li :for={step <- @cook_mode_steps.do_first}
              class="text-sm text-[var(--text)] flex gap-2">
              <span class="text-[color:var(--accent)] mt-0.5">→</span>
              <span>{step}</span>
            </li>
          </ul>
        </div>

        <%= if @cook_mode_steps.while_cooking != [] do %>
          <div>
            <p class="text-xs font-semibold text-[color:var(--muted)] uppercase tracking-wide mb-2">
              {gettext("While it cooks")}
            </p>
            <ul class="space-y-1">
              <li :for={step <- @cook_mode_steps.while_cooking}
                class="text-sm text-[var(--text)] flex gap-2">
                <span class="text-[color:var(--muted)] mt-0.5">→</span>
                <span>{step}</span>
              </li>
            </ul>
          </div>
        <% end %>

        <div>
          <p class="text-xs font-semibold text-[color:var(--muted)] uppercase tracking-wide mb-2">
            {gettext("Finish")}
          </p>
          <ul class="space-y-1">
            <li :for={step <- @cook_mode_steps.finish}
              class="text-sm text-[var(--text)] flex gap-2">
              <span class="text-[color:var(--muted)] mt-0.5">→</span>
              <span>{step}</span>
            </li>
          </ul>
        </div>
      </div>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 5: Start server and verify**

```bash
mix phx.server
```

Open http://localhost:4000/recipes. Open any recipe with instructions. Click "Start cooking". Verify the 3-phase compressed view appears. Verify "Exit" returns to the normal recipe view.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(cook-mode): compressed action-oriented recipe steps via LLM"
```

---

## Task 8: Kitchen Memory UI — "Things Tore has learned"

Adds a "Kitchen Memory" tab to SettingsLive showing the active `family_insights` records with Keep and Forget controls. Requires Phase 7's `Family.list_active_insights/0` and `Family.dismiss_insight/1` functions.

**Files:**
- Modify: `lib/tore_web/live/settings_live.ex`
- Modify: `lib/tore_web/live/settings_live.html.heex` (or inline render in settings_live.ex if it uses `render/1`)

- [ ] **Step 1: Check how SettingsLive renders**

```bash
grep -n "def render\|html.heex\|embed_templates" lib/tore_web/live/settings_live.ex
```

If it has a `.html.heex` template file, modify that. If it uses inline `render/1`, modify the `~H"""` block there.

- [ ] **Step 2: Add memory assigns to SettingsLive mount**

In `lib/tore_web/live/settings_live.ex`, in `mount/3`, add:

```elixir
memory_insights: Tore.Family.list_active_insights()
```

- [ ] **Step 3: Add forget event handler**

```elixir
def handle_event("forget_insight", %{"id" => id}, socket) do
  Tore.Family.dismiss_insight(String.to_integer(id))
  {:noreply, assign(socket, memory_insights: Tore.Family.list_active_insights())}
end
```

- [ ] **Step 4: Add Kitchen Memory section to settings template**

Add this section at the end of the settings page content. The exact location depends on the template structure — add it as the last section before any closing tags.

```heex
<%!-- Kitchen Memory --%>
<section class="mt-8">
  <h2 class="text-lg font-semibold text-[var(--text)] mb-1">
    {gettext("Things Tore has learned")}
  </h2>
  <p class="text-sm text-[color:var(--muted)] mb-4">
    {gettext("Tore observes your patterns over time. Forget anything that no longer applies.")}
  </p>

  <%= if @memory_insights == [] do %>
    <p class="text-sm text-[color:var(--muted)] italic">
      {gettext("No patterns learned yet — check back after a few weeks of planning.")}
    </p>
  <% else %>
    <div class="flex flex-col gap-3">
      <%= for insight <- @memory_insights do %>
        <div class="rounded-2xl border border-[color:var(--hairline)] bg-[color:var(--surface-raised)] p-4 flex items-start justify-between gap-4">
          <div class="flex-1 min-w-0">
            <p class="text-sm text-[var(--text)] leading-relaxed">{insight.body}</p>
            <p class={[
              "text-xs mt-1",
              insight.confidence >= 0.8 && "text-green-600 dark:text-green-400",
              insight.confidence >= 0.5 && insight.confidence < 0.8 && "text-yellow-600 dark:text-yellow-400",
              insight.confidence < 0.5 && "text-[color:var(--muted)]"
            ]}>
              {confidence_label(insight.confidence)}
            </p>
          </div>
          <button
            phx-click="forget_insight"
            phx-value-id={insight.id}
            class="shrink-0 px-3 py-1.5 rounded-xl border border-[color:var(--hairline)] text-[color:var(--muted)] text-xs font-medium hover:border-red-400 hover:text-red-500 transition-colors">
            {gettext("Forget")}
          </button>
        </div>
      <% end %>
    </div>
  <% end %>
</section>
```

Add the helper to `settings_live.ex`:

```elixir
defp confidence_label(c) when c >= 0.8, do: gettext("High confidence")
defp confidence_label(c) when c >= 0.5, do: gettext("Medium confidence")
defp confidence_label(_), do: gettext("Low confidence")
```

- [ ] **Step 5: Start server and verify**

```bash
mix phx.server
```

Open http://localhost:4000/settings. Verify the "Things Tore has learned" section renders. If no insights exist, seed one:

```bash
mix run --no-halt -e '
  Tore.Family.replace_insights([
    %{kind: "skip_pattern", body: "You skip Thursday dinners most weeks — likely eating out.", confidence: 0.85},
    %{kind: "cascade_success", body: "Chicken-based cascades work well and typically survive to Wednesday.", confidence: 0.72}
  ])
'
```

Verify insights appear. Click "Forget" — verify the insight disappears immediately.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(memory): Kitchen Memory tab in settings — view and forget learned patterns"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Counter notes — ambient contextual suggestions inline | Task 1, 2 |
| Counter note schema: surface, kind, title, body, confidence, status, expires_at | Task 1 |
| Counter notes: accept/ignore/expire | Task 1 |
| Counter notes rendered on planner (week surface) | Task 2 |
| Plan health indicator: ready/flexible/fragile/unplanned | Task 3 |
| Plan health updates on PubSub plan events | Task 3, step 5 |
| Week modes: 8 modes, only one active per week | Task 4 |
| Week mode prompt fragment injected into plan_weekly | Task 4, steps 6–7 |
| Week mode selector on planner UI | Task 4, step 8 |
| Contextual command bar on planner | Task 5 |
| Command bar routes through ChatHandler | Task 5, step 2 |
| Inline reply shown after command | Task 5, step 3 |
| Cooking substitution: "Missing something?" on recipe detail | Task 6 |
| `suggest_substitution/2` LLM callback | Task 6, steps 1–4 |
| Cook mode: compressed 3-phase action view | Task 7 |
| `cook_mode_steps/1` LLM callback | Task 7, steps 1–2 |
| Kitchen Memory UI: "Things Tore has learned" in settings | Task 8 |
| Kitchen Memory: Forget control per insight | Task 8, step 3 |

**Items deferred to post-MVP (not in this plan):**
- Counter notes generated automatically by plan generation / deal scraping (this plan adds the infrastructure and manual seeding; the generation hooks go into PlanningHandler and DealsHandler in a follow-up)
- "Make it faster" variant in cook mode (second LLM call, separate task)
- Counter notes on home screen (HomeLive is built in Phase 3, not yet in codebase)
- Change receipts rendered as toast in non-chat contexts (requires toast infrastructure)

**Placeholder scan:** None found. All code blocks are complete.

**Type consistency:**
- `CounterNotes.create/1` takes `map()` with string keys — matched in test and template `phx-value-id` parsing.
- `Tore.PlanHealth.compute/1` takes `map()` with `:slots` key — matched by `plan_state` shape from `PlanningHandler.load_plan/1`.
- `Tore.WeekMode.mode_prompt_fragment/1` takes `String.t()` and returns `String.t() | nil` — `nil` guarded in EEx template with `<%= if assigns[:week_mode_fragment] do %>`.
- `Tore.LLM.suggest_substitution/2` returns `{:ok, %{suggestion: String.t(), updated_steps: String.t() | nil}}` — matched in `handle_info({:run_substitution, ...})`.
- `Tore.LLM.cook_mode_steps/1` returns `{:ok, %{do_first: [String.t()], while_cooking: [String.t()], finish: [String.t()]}}` — matched in `handle_info({:load_cook_mode, ...})` and template `:for` iteration.
- `Family.list_active_insights/0` returns `[FamilyInsights.t()]` (Phase 7) — assigned to `memory_insights`, iterated in template. `insight.body` and `insight.confidence` accessed — match schema fields.
