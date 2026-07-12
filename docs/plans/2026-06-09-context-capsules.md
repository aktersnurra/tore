# Context Capsules (A.4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single junk-drawer `Tore.Chat.SystemPrompt.build/0` with typed, per-run-declared context capsules composed explicitly by each run.

**Architecture:** A `Tore.Harness.Capsule` behaviour (`build/1` + `to_prompt/1`); each capsule is a module with a typed struct that fetches+summarises its own data and renders compact prompt text (or `nil`). A `Tore.Harness.Capsules.compose/2` takes an explicit module list + a ctx map and joins the non-nil prompts. The four sections `SystemPrompt.build/0` assembles today become four capsules; the run-role text becomes each run's own preamble; the date/week-mode framing stays as small inline fragments. Both callers (Orchestrator planner run, ChatHandler) migrate; `SystemPrompt` is deleted.

**Tech Stack:** Elixir, ExUnit, Mox (existing). No new deps. Model-facing English prompts — no gettext/i18n.

**Spec:** `docs/specs/2026-06-09-context-capsules-design.md`

---

## Codebase orientation (read before starting)

The engineer is assumed to know Elixir but not this codebase. Key facts:

- **Single household.** `Tore.Household.get_preferences/0`, `Tore.Household.list_active_insights/0`, and `Tore.Pantry.list_inventory/0` are **arity-0** and operate on the one household. They do **not** take a `household_id`. The ctx map still carries `household_id` for forward-compatibility and because the orchestrator has it, but only `WeekPlanCapsule` actually reads ctx today (it needs `plan_stream_id`).
- **`Tore.Handlers.PlanningHandler.load_plan/1`** returns `{:ok, %Tore.Planning.State{}}` or `{:error, _}`. `State` has fields `week_start`, `slots` (a map of `slot_key => slot`), `pins`. A slot has `recipe_id` and `skipped`. Slot keys look like `"mon_dinner"`.
- **`Tore.Household.prefs_to_dietary_guidance/1`** takes a `%Tore.Household.Preferences{}` and returns a `String.t() | nil`.
- **`Tore.WeekMode.get_current_mode/0`** returns a string like `"normal"`; **`Tore.WeekMode.mode_prompt_fragment/1`** returns `String.t() | nil` (`nil` for `"normal"`).
- **Insight** records have a `.body` string field.
- **Pantry** items have a `.name` string field.
- The existing text shapes live in `lib/tore/chat/system_prompt.ex` — each capsule's `to_prompt/1` must reproduce its section's text **exactly** (it is behavior-preserving for the model).
- Tests use `Tore.DataCase` (`async: false` where they touch the single-household global state). The harness/orchestrator already passes `ctx` with `household_id`, `plan_stream_id`, `week_start` into `dispatch/2`.

The capsule `ctx` map shape (used by `build/1` everywhere):

```elixir
%{household_id: integer(), plan_stream_id: String.t(), week_start: Date.t()}
```

---

## File Structure

```
New: lib/tore/harness/capsule.ex                          # the @behaviour
     lib/tore/harness/capsules.ex                          # compose/2
     lib/tore/harness/capsules/household_preferences_capsule.ex
     lib/tore/harness/capsules/active_insights_capsule.ex
     lib/tore/harness/capsules/week_plan_capsule.ex
     lib/tore/harness/capsules/pantry_beliefs_capsule.ex
Modify: lib/tore/harness/orchestrator.ex                   # @planner_capsules; system_prompt/1; date/week_mode helpers
        lib/tore/chat/chat_handler.ex                       # role preamble + compose; chat_ctx
Delete: lib/tore/chat/system_prompt.ex
New: test/tore/harness/capsules/household_preferences_capsule_test.exs
     test/tore/harness/capsules/active_insights_capsule_test.exs
     test/tore/harness/capsules/week_plan_capsule_test.exs
     test/tore/harness/capsules/pantry_beliefs_capsule_test.exs
     test/tore/harness/capsules_test.exs                    # compose/2
Delete: test/tore/chat/system_prompt_test.exs
```

Each capsule owns one section's data fetch + text shape. `compose/2` is the only assembler. The two callers declare their capsule list and supply ctx. This matches the spec exactly.

---

### Task 1: The capsule behaviour

**Files:**

- Create: `lib/tore/harness/capsule.ex`

This is a behaviour module — no runtime logic to test directly. It is validated by the capsules that implement it (later tasks) and by the compiler. No test file for this task.

- [ ] **Step 1: Write the behaviour**

```elixir
defmodule Tore.Harness.Capsule do
  @moduledoc "A named, typed unit of run context. A struct plus a to_prompt/1."

  @doc "Build the capsule struct from a context map (household_id, plan_stream_id, week_start)."
  @callback build(ctx :: map()) :: struct()

  @doc "Render the capsule struct to compact prompt text, or nil if it contributes nothing."
  @callback to_prompt(struct()) :: String.t() | nil
end
```

- [ ] **Step 2: Compile to verify it is valid**

Run: `mix compile --warnings-as-errors`
Expected: compiles with no warnings.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(harness): Capsule behaviour — build/1 + to_prompt/1 contract"
```

---

### Task 2: HouseholdPreferencesCapsule

**Files:**

- Create: `lib/tore/harness/capsules/household_preferences_capsule.ex`
- Test: `test/tore/harness/capsules/household_preferences_capsule_test.exs`

Source: `Tore.Household.get_preferences/0` + `Tore.Household.prefs_to_dietary_guidance/1`. Text shape (from `system_prompt.ex:30-34`): `"Household preferences: <guidance>."`, or `nil` when guidance is `nil`. Ignores ctx.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Tore.Harness.Capsules.HouseholdPreferencesCapsuleTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Capsules.HouseholdPreferencesCapsule, as: Capsule

  @ctx %{household_id: 1, plan_stream_id: "plan:2026-06-08", week_start: ~D[2026-06-08]}

  test "build/1 captures the dietary guidance string" do
    {:ok, _} = Tore.Household.update_preferences(%{dietary_restrictions: ["vegetarian"]})
    capsule = Capsule.build(@ctx)
    assert is_binary(capsule.guidance)
    assert capsule.guidance =~ "vegetarian" or capsule.guidance =~ "Vegetarian"
  end

  test "to_prompt/1 renders the guidance into the household-preferences line" do
    {:ok, _} = Tore.Household.update_preferences(%{dietary_restrictions: ["vegetarian"]})
    prompt = @ctx |> Capsule.build() |> Capsule.to_prompt()
    assert prompt =~ "Household preferences:"
    assert String.ends_with?(prompt, ".")
  end

  test "to_prompt/1 is nil when there is no guidance" do
    # default preferences (no restrictions/allergies/etc.) → nil guidance
    capsule = Capsule.build(@ctx)
    assert capsule.guidance == nil
    assert Capsule.to_prompt(capsule) == nil
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tore/harness/capsules/household_preferences_capsule_test.exs`
Expected: FAIL with `module Tore.Harness.Capsules.HouseholdPreferencesCapsule is not available`.

- [ ] **Step 3: Write the capsule**

```elixir
defmodule Tore.Harness.Capsules.HouseholdPreferencesCapsule do
  @behaviour Tore.Harness.Capsule

  alias Tore.Household

  defstruct [:guidance]

  @type t :: %__MODULE__{guidance: String.t() | nil}

  @impl true
  def build(_ctx) do
    guidance = Household.prefs_to_dietary_guidance(Household.get_preferences())
    %__MODULE__{guidance: guidance}
  end

  @impl true
  def to_prompt(%__MODULE__{guidance: nil}), do: nil
  def to_prompt(%__MODULE__{guidance: guidance}), do: "Household preferences: #{guidance}."
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tore/harness/capsules/household_preferences_capsule_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): HouseholdPreferencesCapsule — dietary guidance"
jj new
```

---

### Task 3: ActiveInsightsCapsule

**Files:**

- Create: `lib/tore/harness/capsules/active_insights_capsule.ex`
- Test: `test/tore/harness/capsules/active_insights_capsule_test.exs`

Source: `Tore.Household.list_active_insights/0`, take 5. Text shape (from `system_prompt.ex:93-103`): `"Household patterns:\n- <body>\n- <body>"`, or `nil` when empty. Ignores ctx.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Tore.Harness.Capsules.ActiveInsightsCapsuleTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Capsules.ActiveInsightsCapsule, as: Capsule

  @ctx %{household_id: 1, plan_stream_id: "plan:2026-06-08", week_start: ~D[2026-06-08]}

  test "build/1 collects active insight bodies" do
    {:ok, _} =
      Tore.Household.replace_insights([
        %{kind: "skip_pattern", body: "Mondays are often skipped.", confidence: 0.8, evidence: []}
      ])

    capsule = Capsule.build(@ctx)
    assert "Mondays are often skipped." in capsule.bodies
  end

  test "build/1 caps the bodies at 5" do
    insights =
      for n <- 1..8 do
        %{kind: "skip_pattern", body: "pattern #{n}", confidence: 0.5, evidence: []}
      end

    {:ok, _} = Tore.Household.replace_insights(insights)

    assert length(Capsule.build(@ctx).bodies) == 5
  end

  test "to_prompt/1 renders a bulleted patterns list" do
    {:ok, _} =
      Tore.Household.replace_insights([
        %{kind: "skip_pattern", body: "Mondays are often skipped.", confidence: 0.8, evidence: []}
      ])

    prompt = @ctx |> Capsule.build() |> Capsule.to_prompt()
    assert prompt =~ "Household patterns:"
    assert prompt =~ "- Mondays are often skipped."
  end

  test "to_prompt/1 is nil when there are no insights" do
    capsule = Capsule.build(@ctx)
    assert capsule.bodies == []
    assert Capsule.to_prompt(capsule) == nil
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tore/harness/capsules/active_insights_capsule_test.exs`
Expected: FAIL with `module ... is not available`.

- [ ] **Step 3: Write the capsule**

```elixir
defmodule Tore.Harness.Capsules.ActiveInsightsCapsule do
  @behaviour Tore.Harness.Capsule

  alias Tore.Household

  defstruct bodies: []

  @type t :: %__MODULE__{bodies: [String.t()]}

  @impl true
  def build(_ctx) do
    bodies =
      Household.list_active_insights()
      |> Enum.take(5)
      |> Enum.map(& &1.body)

    %__MODULE__{bodies: bodies}
  end

  @impl true
  def to_prompt(%__MODULE__{bodies: []}), do: nil

  def to_prompt(%__MODULE__{bodies: bodies}) do
    lines = Enum.map_join(bodies, "\n", fn body -> "- #{body}" end)
    "Household patterns:\n#{lines}"
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tore/harness/capsules/active_insights_capsule_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): ActiveInsightsCapsule — up to 5 household patterns"
jj new
```

---

### Task 4: PantryBeliefsCapsule

**Files:**

- Create: `lib/tore/harness/capsules/pantry_beliefs_capsule.ex`
- Test: `test/tore/harness/capsules/pantry_beliefs_capsule_test.exs`

Source: `Tore.Pantry.list_inventory/0`. Text shape (from `system_prompt.ex:80-91`): names capped at 20, `"Pantry has: a, b, c."` plus ` and N more` when over 20. `nil` when empty. Ignores ctx. The capsule stores `names` (≤20) and `total` (full count).

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Tore.Harness.Capsules.PantryBeliefsCapsuleTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Capsules.PantryBeliefsCapsule, as: Capsule

  @ctx %{household_id: 1, plan_stream_id: "plan:2026-06-08", week_start: ~D[2026-06-08]}

  test "build/1 caps names at 20 but keeps the full total" do
    for n <- 1..25, do: Tore.Pantry.add_item(%{name: "item #{n}", quantity: 1})

    capsule = Capsule.build(@ctx)
    assert length(capsule.names) == 20
    assert capsule.total == 25
  end

  test "to_prompt/1 lists names and the overflow count" do
    for n <- 1..25, do: Tore.Pantry.add_item(%{name: "item #{n}", quantity: 1})

    prompt = @ctx |> Capsule.build() |> Capsule.to_prompt()
    assert prompt =~ "Pantry has:"
    assert prompt =~ "and 5 more"
    assert String.ends_with?(prompt, ".")
  end

  test "to_prompt/1 has no overflow clause at or below 20 items" do
    for n <- 1..3, do: Tore.Pantry.add_item(%{name: "item #{n}", quantity: 1})

    prompt = @ctx |> Capsule.build() |> Capsule.to_prompt()
    assert prompt =~ "Pantry has:"
    refute prompt =~ "more"
  end

  test "to_prompt/1 is nil for an empty pantry" do
    capsule = Capsule.build(@ctx)
    assert capsule.names == []
    assert capsule.total == 0
    assert Capsule.to_prompt(capsule) == nil
  end
end
```

> **Note for implementer:** Confirm the pantry seeding helper. Run `grep -n "def add_item\|def create" lib/tore/pantry.ex` first. If `add_item/1` does not exist, use whatever the canonical creation function is (e.g. `Tore.Pantry.create/1`) with the same `%{name: ..., quantity: ...}` attrs. Do not invent a function — match the real API.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tore/harness/capsules/pantry_beliefs_capsule_test.exs`
Expected: FAIL with `module ... is not available`.

- [ ] **Step 3: Write the capsule**

```elixir
defmodule Tore.Harness.Capsules.PantryBeliefsCapsule do
  @behaviour Tore.Harness.Capsule

  alias Tore.Pantry

  defstruct names: [], total: 0

  @type t :: %__MODULE__{names: [String.t()], total: non_neg_integer()}

  @impl true
  def build(_ctx) do
    items = Pantry.list_inventory()
    names = items |> Enum.map(& &1.name) |> Enum.take(20)
    %__MODULE__{names: names, total: length(items)}
  end

  @impl true
  def to_prompt(%__MODULE__{names: []}), do: nil

  def to_prompt(%__MODULE__{names: names, total: total}) do
    overflow = if total > 20, do: " and #{total - 20} more", else: ""
    "Pantry has: #{Enum.join(names, ", ")}#{overflow}."
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tore/harness/capsules/pantry_beliefs_capsule_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): PantryBeliefsCapsule — inventory names capped at 20 + count"
jj new
```

---

### Task 5: WeekPlanCapsule

**Files:**

- Create: `lib/tore/harness/capsules/week_plan_capsule.ex`
- Test: `test/tore/harness/capsules/week_plan_capsule_test.exs`

Source: `Tore.Handlers.PlanningHandler.load_plan(ctx.plan_stream_id)` → `{:ok, %State{}}`. This capsule **reads ctx** (`plan_stream_id`, `week_start`). Text shape (from `system_prompt.ex:56-78`): one line per day Monday–Sunday, each `"  <DayName> <iso-date>: <status>"`, prefixed by `"This week's dinner plan:\n"`. Status is `"empty"` (no slot / no recipe_id), `"skipped"` (slot.skipped), else `"assigned"`. Returns `nil` if the plan cannot be loaded.

The capsule stores typed slots so a future UI/verifier can read the struct (`status ∈ :empty | :assigned | :skipped`); `to_prompt/1` renders the same text the old code produced. Day name → slot-key uses the first three letters lowercased (`"Monday"` → `"mon_dinner"`), matching `format_plan_state`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Tore.Harness.Capsules.WeekPlanCapsuleTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Capsules.WeekPlanCapsule, as: Capsule
  alias Tore.{Handlers.PlanningHandler, Recipes}

  defp ctx_for(week_start) do
    %{
      household_id: 1,
      plan_stream_id: "plan:#{Date.to_iso8601(week_start)}",
      week_start: week_start
    }
  end

  test "build/1 has seven slots, Monday through Sunday, with statuses" do
    week_start = ~D[2026-06-08]
    ctx = ctx_for(week_start)

    {:ok, recipe} =
      Recipes.create(%{
        title: "Roast chicken",
        recipe_type: :meal,
        base_servings: 4,
        prep_time_minutes: 10,
        cook_time_minutes: 30
      })

    PlanningHandler.assign_recipe(ctx.plan_stream_id, "tue_dinner", recipe.id, 4)

    capsule = Capsule.build(ctx)
    assert length(capsule.slots) == 7
    [mon, tue | _] = capsule.slots
    assert mon.day == "Monday"
    assert mon.status == :empty
    assert tue.day == "Tuesday"
    assert tue.status == :assigned
  end

  test "to_prompt/1 renders the dinner plan with one line per day" do
    week_start = ~D[2026-06-08]
    ctx = ctx_for(week_start)

    prompt = ctx |> Capsule.build() |> Capsule.to_prompt()
    assert prompt =~ "This week's dinner plan:"
    assert prompt =~ "Monday 2026-06-08: empty"
    assert prompt =~ "Sunday 2026-06-14: empty"
  end

  test "to_prompt/1 is nil when the plan cannot be loaded" do
    # A ctx whose plan_stream_id is malformed → load_plan returns {:error, _}
    bad_ctx = %{household_id: 1, plan_stream_id: nil, week_start: ~D[2026-06-08]}
    capsule = Capsule.build(bad_ctx)
    assert capsule.slots == nil
    assert Capsule.to_prompt(capsule) == nil
  end
end
```

> **Note for implementer:** Confirm `PlanningHandler.assign_recipe/4` exists and its arg order is `(plan_id, slot_key, recipe_id, servings)` — `grep -n "def assign_recipe" lib/tore/handlers/planning_handler.ex`. It is used the same way in `test/tore_web/live/planner_live_test.exs:89`. Confirm `load_plan(nil)` (or another malformed id) returns `{:error, _}` rather than raising; if it raises, the `build/1` clause below already rescues into `slots: nil`, so the third test still passes — but verify the rescue path is hit.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tore/harness/capsules/week_plan_capsule_test.exs`
Expected: FAIL with `module ... is not available`.

- [ ] **Step 3: Write the capsule**

```elixir
defmodule Tore.Harness.Capsules.WeekPlanCapsule do
  @behaviour Tore.Harness.Capsule

  alias Tore.Handlers.PlanningHandler

  @day_names ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

  defstruct [:week_start, :slots]

  @type slot :: %{day: String.t(), date: Date.t(), status: :empty | :assigned | :skipped}
  @type t :: %__MODULE__{week_start: Date.t() | nil, slots: [slot()] | nil}

  @impl true
  def build(ctx) do
    case PlanningHandler.load_plan(ctx.plan_stream_id) do
      {:ok, state} ->
        %__MODULE__{week_start: ctx.week_start, slots: build_slots(state, ctx.week_start)}

      _ ->
        %__MODULE__{week_start: ctx.week_start, slots: nil}
    end
  rescue
    _ -> %__MODULE__{week_start: ctx.week_start, slots: nil}
  end

  @impl true
  def to_prompt(%__MODULE__{slots: nil}), do: nil

  def to_prompt(%__MODULE__{slots: slots}) do
    lines =
      Enum.map_join(slots, "\n", fn s ->
        "  #{s.day} #{Date.to_iso8601(s.date)}: #{s.status}"
      end)

    "This week's dinner plan:\n#{lines}"
  end

  defp build_slots(state, week_start) do
    Enum.with_index(@day_names, fn day_name, i ->
      date = Date.add(week_start, i)
      slot_key = "#{String.downcase(String.slice(day_name, 0..2))}_dinner"
      %{day: day_name, date: date, status: slot_status(Map.get(state.slots, slot_key))}
    end)
  end

  defp slot_status(nil), do: :empty
  defp slot_status(%{recipe_id: nil}), do: :empty
  defp slot_status(%{skipped: true}), do: :skipped
  defp slot_status(_slot), do: :assigned
end
```

> **Implementer note on `to_prompt` status rendering:** `#{s.status}` interpolates the atom (`:empty` → `"empty"`), which reproduces the old text exactly. Keep it as the atom; do not convert to a string in the struct — the typed atom is the §A.4 "read the struct" property.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tore/harness/capsules/week_plan_capsule_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): WeekPlanCapsule — per-day dinner status from the plan stream"
jj new
```

---

### Task 6: Capsules.compose/2

**Files:**

- Create: `lib/tore/harness/capsules.ex`
- Test: `test/tore/harness/capsules_test.exs`

`compose/2` builds each declared capsule from ctx, renders it, drops `nil`, joins with blank lines, preserving declared order. The test uses the real capsules from Tasks 2–5 (they are committed by now), seeding data so at least one renders and one is `nil`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Tore.Harness.CapsulesTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Capsules

  alias Tore.Harness.Capsules.{
    HouseholdPreferencesCapsule,
    ActiveInsightsCapsule,
    PantryBeliefsCapsule
  }

  @ctx %{household_id: 1, plan_stream_id: "plan:2026-06-08", week_start: ~D[2026-06-08]}

  test "compose/2 joins rendered capsules and drops nils, preserving order" do
    {:ok, _} = Tore.Household.update_preferences(%{dietary_restrictions: ["vegetarian"]})
    # no insights seeded → ActiveInsightsCapsule renders nil and is dropped

    prompt =
      Capsules.compose([HouseholdPreferencesCapsule, ActiveInsightsCapsule], @ctx)

    assert prompt =~ "Household preferences:"
    refute prompt =~ "Household patterns:"
  end

  test "compose/2 returns an empty string when every capsule renders nil" do
    # nothing seeded: no prefs, no insights, no pantry → all nil
    prompt =
      Capsules.compose(
        [HouseholdPreferencesCapsule, ActiveInsightsCapsule, PantryBeliefsCapsule],
        @ctx
      )

    assert prompt == ""
  end

  test "compose/2 separates two rendered capsules with a blank line" do
    {:ok, _} = Tore.Household.update_preferences(%{dietary_restrictions: ["vegetarian"]})

    {:ok, _} =
      Tore.Household.replace_insights([
        %{kind: "skip_pattern", body: "Mondays are often skipped.", confidence: 0.8, evidence: []}
      ])

    prompt =
      Capsules.compose([HouseholdPreferencesCapsule, ActiveInsightsCapsule], @ctx)

    assert prompt =~ "Household preferences:"
    assert prompt =~ "Household patterns:"
    assert prompt =~ "\n\n"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tore/harness/capsules_test.exs`
Expected: FAIL with `module Tore.Harness.Capsules is not available`.

- [ ] **Step 3: Write compose/2**

```elixir
defmodule Tore.Harness.Capsules do
  @moduledoc "Composes a run's declared capsule list into its prompt context."

  @doc """
  Build each declared capsule from ctx, render it, drop nils, join with blank
  lines. `capsule_modules` is the run's explicit, static capsule list; order is
  preserved.
  """
  @spec compose([module()], map()) :: String.t()
  def compose(capsule_modules, ctx) do
    capsule_modules
    |> Enum.map(fn mod -> mod.to_prompt(mod.build(ctx)) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/tore/harness/capsules_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(harness): Capsules.compose/2 — explicit per-run capsule composition"
jj new
```

---

### Task 7: Migrate the Orchestrator planner run onto capsules

**Files:**

- Modify: `lib/tore/harness/orchestrator.ex` (the `system_prompt/0` call site at `:26`, the `system_prompt/0` def at `:193-195`, add capsule list + helpers)

`system_prompt/0` becomes `system_prompt/1` taking `ctx`. It composes: the planner's own `agent_preamble()` (removing the **doubled** role — the old `SystemPrompt.build/0` also prepended a `role_section`, so the planner was double-prefixed; this migration drops that), a date line, an optional week-mode line, and `Capsules.compose(@planner_capsules, capsule_ctx(ctx))`.

> **Implementer note:** There is no existing orchestrator unit test that asserts prompt contents (the planner-run tests in `test/tore_web/live/planner_live_test.exs` mock the LLM and ignore the system prompt). So this task adds a focused test asserting `dispatch/2` still works and the composed prompt carries the household/week context. Capture the system prompt by having the Mox expectation assert on its `sys` argument.

- [ ] **Step 1: Write the failing test**

Create `test/tore/harness/orchestrator_system_prompt_test.exs`:

```elixir
defmodule Tore.Harness.OrchestratorSystemPromptTest do
  use Tore.DataCase, async: false
  import Mox

  setup :verify_on_exit!

  alias Tore.Harness.Orchestrator

  defp this_week_start do
    today = Date.utc_today()
    Date.add(today, -(Date.day_of_week(today) - 1))
  end

  test "the planner run's system prompt carries the composed household + week context" do
    {:ok, _} = Tore.Household.update_preferences(%{dietary_restrictions: ["vegetarian"]})

    test_pid = self()

    Mox.expect(Tore.MockLLM, :chat_with_tools, fn sys, _msgs, _tools, _opts ->
      send(test_pid, {:system_prompt, sys})
      {:ok, {:message, "Done."}, %{}}
    end)

    week_start = this_week_start()

    ctx = %{
      household_id: 1,
      user_id: nil,
      command: "what's for dinner",
      plan_stream_id: "plan:#{Date.to_iso8601(week_start)}",
      week_start: week_start
    }

    {:ok, _state} = Orchestrator.dispatch(:planner_command_run, ctx)

    assert_receive {:system_prompt, sys}
    # planner identity present exactly once (no doubled role section)
    assert sys =~ "You are the planner agent for Tore"
    # composed capsule context present
    assert sys =~ "Household preferences:"
    assert sys =~ "This week's dinner plan:"
    # the old chat role_section line must NOT be present (it was the duplicate)
    refute sys =~ "friendly and practical AI cooking and meal planning assistant"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/harness/orchestrator_system_prompt_test.exs`
Expected: FAIL — the test asserts `refute sys =~ "friendly and practical AI cooking..."`, but the current `system_prompt/0` still calls `SystemPrompt.build()` which includes that role section. (It may fail on the `refute` or because `system_prompt/0` does not yet take ctx; either way it is red before the change.)

- [ ] **Step 3: Add the capsule alias and module attribute**

In `lib/tore/harness/orchestrator.ex`, add to the alias block near the top (after the existing `alias Tore.Harness.Verifier.PlanVerifier` at `:10`):

```elixir
  alias Tore.Harness.Capsules

  alias Tore.Harness.Capsules.{
    HouseholdPreferencesCapsule,
    ActiveInsightsCapsule,
    WeekPlanCapsule,
    PantryBeliefsCapsule
  }

  @planner_capsules [
    HouseholdPreferencesCapsule,
    ActiveInsightsCapsule,
    WeekPlanCapsule,
    PantryBeliefsCapsule
  ]
```

- [ ] **Step 4: Update the call site to pass ctx**

In `dispatch/2`, change the `PlannerAgent.run` line (`:26`) from:

```elixir
             {:ok, loop} <- PlannerAgent.run(system_prompt(), ctx.command, agent_ctx(ctx, stream_id, working_plan), []),
```

to:

```elixir
             {:ok, loop} <- PlannerAgent.run(system_prompt(ctx), ctx.command, agent_ctx(ctx, stream_id, working_plan), []),
```

- [ ] **Step 5: Replace `system_prompt/0` with `system_prompt/1` + helpers**

Replace the def at `:193-195`:

```elixir
  defp system_prompt do
    agent_preamble() <> "\n\n" <> Tore.Chat.SystemPrompt.build()
  end
```

with:

```elixir
  defp system_prompt(ctx) do
    [
      agent_preamble(),
      date_line(),
      week_mode_line(),
      Capsules.compose(@planner_capsules, capsule_ctx(ctx))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp date_line do
    "Today is #{Calendar.strftime(Date.utc_today(), "%A, %B %-d, %Y")}."
  end

  defp week_mode_line do
    case Tore.WeekMode.mode_prompt_fragment(Tore.WeekMode.get_current_mode()) do
      nil -> nil
      fragment -> "Current week mode: #{fragment}"
    end
  end

  defp capsule_ctx(ctx) do
    %{
      household_id: ctx.household_id,
      plan_stream_id: ctx.plan_stream_id,
      week_start: ctx.week_start
    }
  end
```

- [ ] **Step 6: Run the new test to verify it passes**

Run: `mix test test/tore/harness/orchestrator_system_prompt_test.exs`
Expected: PASS (1 test).

- [ ] **Step 7: Run the planner LiveView tests to confirm no regression**

Run: `mix test test/tore_web/live/planner_live_test.exs`
Expected: PASS (all tests — the command-bar tests still pass; they mock the LLM and don't assert on prompt).

- [ ] **Step 8: Commit**

```bash
jj describe -m "refactor(harness): planner run composes capsules; drop doubled role section"
jj new
```

---

### Task 8: Migrate ChatHandler onto capsules

**Files:**

- Modify: `lib/tore/chat/chat_handler.ex` (alias at `:2`, `system = SystemPrompt.build()` at `:8`)

The chat handler keeps its own short role preamble (the role text that lived in `SystemPrompt.role_section`), then composes the same four capsules. It builds its own ctx from today's current week.

> **Note for implementer:** Check whether a chat-handler test exists: `ls test/tore/chat/`. There is no dedicated `chat_handler_test.exs` today (only `system_prompt_test.exs`, which Task 9 deletes). So add a focused test here that the composed chat system prompt includes the role line and the household context.

- [ ] **Step 1: Write the failing test**

Create `test/tore/chat/chat_handler_test.exs`:

```elixir
defmodule Tore.Chat.ChatHandlerTest do
  use Tore.DataCase, async: false
  import Mox

  setup :verify_on_exit!

  test "the chat system prompt includes the role preamble and composed household context" do
    {:ok, _} = Tore.Household.update_preferences(%{dietary_restrictions: ["vegetarian"]})
    test_pid = self()

    Mox.expect(Tore.MockLLM, :chat, fn sys, _messages ->
      send(test_pid, {:system_prompt, sys})
      {:ok, "Hej!", %{}}
    end)

    {:ok, _reply, nil} = Tore.Chat.ChatHandler.handle_text("hello")

    assert_receive {:system_prompt, sys}
    assert sys =~ "Tore"
    assert sys =~ "Household preferences:"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/chat/chat_handler_test.exs`
Expected: FAIL with `(Mox.UnexpectedCallError)` or `no expectation defined` — the **current** handler calls `@llm.chat(system, messages)` but does not surface the system prompt to the test, and more importantly the old `SystemPrompt.build/0` path is what's exercised. The clean failure signal: this test mocks `Tore.MockLLM.chat/2` and asserts the prompt was *sent*; if the handler's contract changes (Step 3 rewrites it to compose capsules), the assertion validates the new path. If the test happens to pass against the old code (because old `build/0` also contained "Tore"/"Household preferences:"), that is acceptable — the binding red gate for this migration is Task 9 Step 3 (`mix compile --warnings-as-errors` after `SystemPrompt` is deleted): the handler will fail to compile if Step 3 did not remove the `SystemPrompt` dependency. Treat that compile as the migration's true verification and proceed.

- [ ] **Step 3: Rewrite the handler to compose capsules**

Replace the alias line `:2`:

```elixir
  alias Tore.{AiOperations, Chat.SystemPrompt}
```

with:

```elixir
  alias Tore.AiOperations
  alias Tore.Harness.Capsules

  alias Tore.Harness.Capsules.{
    HouseholdPreferencesCapsule,
    ActiveInsightsCapsule,
    WeekPlanCapsule,
    PantryBeliefsCapsule
  }

  @chat_capsules [
    HouseholdPreferencesCapsule,
    ActiveInsightsCapsule,
    WeekPlanCapsule,
    PantryBeliefsCapsule
  ]

  @role_preamble "You are Tore, a friendly and practical AI cooking and meal planning assistant.\nHelp the household plan meals, manage groceries, and make the most of what they have.\nRespond conversationally in the user's language. Be concise and warm."
```

Replace `system = SystemPrompt.build()` at `:8`:

```elixir
    system = SystemPrompt.build()
```

with:

```elixir
    system =
      [@role_preamble, Capsules.compose(@chat_capsules, chat_ctx())]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
```

Add this private helper at the end of the module (before the final `end`), alongside `generate_correlation_id/0`:

```elixir
  defp chat_ctx do
    today = Date.utc_today()
    week_start = Date.add(today, -(Date.day_of_week(today) - 1))

    %{
      household_id: nil,
      plan_stream_id: "plan:#{Date.to_iso8601(week_start)}",
      week_start: week_start
    }
  end
```

> **Implementer note on `household_id: nil`:** the four capsules built here ignore `household_id` (single household), so `nil` is safe. Keep the key present so the ctx shape matches the spec.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/tore/chat/chat_handler_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(chat): ChatHandler composes capsules + own role preamble"
jj new
```

---

### Task 9: Delete SystemPrompt and its test

**Files:**

- Delete: `lib/tore/chat/system_prompt.ex`
- Delete: `test/tore/chat/system_prompt_test.exs`

All callers migrated (Tasks 7, 8). The behavioral assertions in `system_prompt_test.exs` (dietary/insights/week/pantry text + assistant name) are reproduced in the per-capsule tests + the orchestrator and chat-handler prompt tests.

- [ ] **Step 1: Verify there are no remaining references**

Run: `grep -rn "SystemPrompt" lib/ test/`
Expected: **no output** (zero references). If any remain, fix them before deleting.

- [ ] **Step 2: Delete the module and its test**

```bash
rm lib/tore/chat/system_prompt.ex test/tore/chat/system_prompt_test.exs
```

- [ ] **Step 3: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: clean compile, no "undefined module" or unused-alias warnings.

- [ ] **Step 4: Run the full suite**

Run: `mix test`
Expected: all green. (One rare, pre-existing SQLite "Database busy" flake under parallel load is not a regression — re-run if it appears.)

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(chat): delete SystemPrompt.build/0 — fully replaced by capsules"
jj new
```

---

### Task 10: Full-suite verification + format

**Files:** none (verification task)

- [ ] **Step 1: Format**

Run: `mix format`
Then confirm nothing unexpected changed: `jj diff --stat`

- [ ] **Step 2: Compile clean**

Run: `mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 3: Full test suite**

Run: `mix test`
Expected: full suite green (the prior count was 476 + the new capsule/compose/orchestrator/chat tests, minus the 4 deleted SystemPrompt tests).

- [ ] **Step 4: Append to CHANGELOG**

Add an entry under the appropriate section of `CHANGELOG.md`:

```markdown
- **A.4 Context capsules** — replaced `Tore.Chat.SystemPrompt.build/0` with typed,
  per-run-declared context capsules (`Tore.Harness.Capsule` behaviour +
  `Capsules.compose/2`). Four capsules: HouseholdPreferences, ActiveInsights,
  WeekPlan, PantryBeliefs. Planner run and chat handler now declare their capsule
  lists explicitly; the planner's doubled role section is removed.
```

- [ ] **Step 5: Commit**

```bash
jj describe -m "chore: format + CHANGELOG for context capsules"
jj new
```

---

## Notes for the executor

- **VCS is jj, never git.** Each task ends with `jj describe -m "..."` then `jj new` to start the next change on top. Do not run `git` commands. Push to master happens after the whole plan + review, via the finishing-a-development-branch skill — not per task.
- **Smoke tests are user-run.** Do not attempt live-LLM smoke tests; they require the API key, which is the user's. Mox covers the deterministic paths.
- **No i18n.** These are model-facing English prompts. Do not touch gettext.
- **Touch only what each task names.** Do not refactor adjacent code, the old `generate_plan/1` path, or the planner tools.
- **Confirm-before-invent:** two tasks (4, 5) ask you to `grep` for the exact pantry/plan API before seeding test data. Match the real function names; do not invent them.
