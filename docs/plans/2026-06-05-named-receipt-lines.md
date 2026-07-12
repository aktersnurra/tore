# Named per-change receipt lines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the run receipt's `Applied` body as a list of localized per-change lines that name the recipe and day, built from the PlanDiff rollup.

**Architecture:** `ToreWeb.Components.ReceiptLive` (the only file changed) gains an `applied_lines/1` that reads the `PlanDiff` artifact from the `Applied` state, calls `PlanDiff.summarise/1`, and maps each rollup entry to a localized line via `line_for/1` + a `day_name/1`. `update/2` assigns a `body_lines` list for Applied (nil otherwise); `render/2` renders a `<ul>` when `body_lines` is a list, else the existing single body.

**Tech Stack:** Elixir, Phoenix LiveComponent, gettext, ExUnit. VCS is **jj (Jujutsu), never git**.

**Spec:** `docs/specs/2026-06-05-named-receipt-lines-design.md`

**Baseline:** Pre-existing test floor is ~5–8 failures in `Tore.Groceries.*` / `GroceriesHandlerTest` (Mox race), unrelated. "No new failures" = that floor unchanged.

**VCS discipline:** Start each task with `jj st`; if the working copy is not clean/empty, `jj new` before editing. End each task with `jj describe -m "<msg>"` then `jj new`.

---

## Reference: current code & shapes

Current `lib/tore_web/components/receipt_live.ex` relevant parts:

```elixir
  alias Tore.Harness.Run.State
  alias Tore.Harness.Artifact
  alias Tore.Harness.Artifact.RunSummary

  def update(%{run: run} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:header_text, header_for(run))
     |> assign(:body_html, body(run))}
  end

  def render(assigns) do
    ~H"""
    <div class="rounded-2xl border border-[color:var(--hairline)] bg-[color:var(--surface-raised)] p-4">
      <p class="text-[10px] font-semibold text-[color:var(--accent)] uppercase tracking-widest mb-1">
        {@header_text}
      </p>
      <div class="text-sm text-[color:var(--ink)]">
        {Phoenix.HTML.raw(@body_html)}
      </div>
    </div>
    """
  end

  defp body(%State.Running{phase: phase}), do: escape(phase_label(phase))
  defp body(%State.NeedsUser{question: q}), do: escape(q)
  defp body(%State.Applied{artifacts: artifacts}), do: escape(summary_text(artifacts))
  defp body(%State.Failed{failure_user_message: msg}), do: escape(msg)
  defp body(%State.Reverted{}), do: escape(gettext("Changes reverted."))

  defp summary_text(artifacts) do
    case Enum.find(artifacts, fn a -> match?(%RunSummary{}, a) end) do
      nil -> gettext("Done.")
      %RunSummary{} = rs -> Artifact.summary(rs).text_fallback
    end
  end
```

- `Tore.Harness.Artifact.PlanDiff.summarise/1` returns a list of
  `%{slot_key: String.t(), change: atom, label: String.t() | nil, rationale: [String.t()]}`.
  `change ∈ :added | :swapped | :skipped | :leftover | :removed | :servings`.
- A slot_key looks like `"sat_dinner"`; the day token is the part before `_`.
- `%State.Applied{artifacts: [...]}` holds the rehydrated PlanDiff + RunSummary.
- Existing test file `test/tore_web/components/receipt_live_test.exs` builds
  `%State.Applied{...}` with a `PlanDiff` and a `RunSummary` in `artifacts` and
  renders via `render_component(ReceiptLive, id: "r", run: applied)`.

---

## Task 1: Render Applied body as named per-change lines

**Files:**
- Modify: `lib/tore_web/components/receipt_live.ex`
- Test: `test/tore_web/components/receipt_live_test.exs`

- [ ] **Step 1: Read the existing Applied test to reuse its fixtures**

Run: `grep -n "Applied\|PlanDiff\|RunSummary\|render_component\|alias" test/tore_web/components/receipt_live_test.exs`
Note the existing `Applied` test's setup (how it builds `%PlanDiff{}` and the `%State.Applied{}` struct), so the new tests reuse the same field shapes. The existing Applied test currently asserts on the RunSummary text (e.g. "Tore adjusted the plan" header and a "skipped" count) — that assertion will need updating in Step 7 because the body is now per-change lines.

- [ ] **Step 2: Add failing tests for named lines**

Add these tests to `test/tore_web/components/receipt_live_test.exs` (match the file's existing aliases: `alias ToreWeb.Components.ReceiptLive`, `alias Tore.Harness.Run.State`, `alias Tore.Harness.Artifact.{PlanDiff, RunSummary}`; build the `%State.Applied{}` exactly like the existing Applied test, varying only the PlanDiff `events`).

```elixir
  defp applied_with_events(events) do
    diff = %PlanDiff{plan_stream_id: "plan-1", week_start: ~D[2026-06-01], events: events}
    rs = RunSummary.from_artifacts([diff], :applied)

    %State.Applied{
      stream_id: "run-x", household_id: 1, kind: "planner_command_run",
      surface: :plan, started_by: "user", user_id: 1, input: %{},
      opened_at: ~U[2026-06-02 12:00:00Z], committed_at: ~U[2026-06-02 12:01:00Z],
      tool_trace: [], artifacts: [diff, rs],
      model_usage: %{prompt_tokens: 0, completion_tokens: 0, cost_usd: Decimal.new(0)}
    }
  end

  test "Applied renders a named line for a swapped recipe with the day" do
    events = [%{slot_key: "sat_dinner", event_type: "RecipeSwapped",
                payload: %{"label" => "Ugnsraggmunk", "to_slot_key" => "sat_dinner"},
                rationale: ["x"]}]
    html = render_component(ReceiptLive, id: "r", run: applied_with_events(events))
    assert html =~ "Ugnsraggmunk"
    assert html =~ "Saturday"
  end

  test "Applied renders a day-only line for a skip (no recipe name)" do
    events = [%{slot_key: "sun_dinner", event_type: "MealSkipped", payload: %{}, rationale: ["x"]}]
    html = render_component(ReceiptLive, id: "r", run: applied_with_events(events))
    assert html =~ "Skipped"
    assert html =~ "Sunday"
  end

  test "Applied renders an added recipe line" do
    events = [%{slot_key: "mon_dinner", event_type: "RecipeAssigned",
                payload: %{"label" => "Roast chicken", "recipe_id" => 1, "servings" => 4},
                rationale: ["x"]}]
    html = render_component(ReceiptLive, id: "r", run: applied_with_events(events))
    assert html =~ "Added"
    assert html =~ "Roast chicken"
    assert html =~ "Monday"
  end

  test "Applied renders multiple lines, one per change" do
    events = [
      %{slot_key: "sat_dinner", event_type: "RecipeSwapped",
        payload: %{"label" => "Ugnsraggmunk", "to_slot_key" => "sat_dinner"}, rationale: ["x"]},
      %{slot_key: "sun_dinner", event_type: "MealSkipped", payload: %{}, rationale: ["y"]}
    ]
    html = render_component(ReceiptLive, id: "r", run: applied_with_events(events))
    assert html =~ "Ugnsraggmunk"
    assert html =~ "Sunday"
    # two <li> items rendered
    assert length(Regex.scan(~r/<li/, html)) == 2
  end

  test "Applied with an added change but nil label falls back to day-only phrasing" do
    events = [%{slot_key: "mon_dinner", event_type: "RecipeAssigned",
                payload: %{"recipe_id" => 1, "servings" => 4}, rationale: ["x"]}]
    html = render_component(ReceiptLive, id: "r", run: applied_with_events(events))
    assert html =~ "Added a meal"
    assert html =~ "Monday"
    refute html =~ "nil"
  end

  test "Applied with no PlanDiff events renders a No changes line" do
    html = render_component(ReceiptLive, id: "r", run: applied_with_events([]))
    assert html =~ "No changes"
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mix test test/tore_web/components/receipt_live_test.exs`
Expected: the new tests FAIL (current Applied body is the single RunSummary count string, no per-change lines / no `<li>`).

- [ ] **Step 4: Update `update/2` to compute `body_lines`**

In `lib/tore_web/components/receipt_live.ex`, change `update/2` to also assign `body_lines`:

```elixir
  def update(%{run: run} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:header_text, header_for(run))
     |> assign(:body_html, body(run))
     |> assign(:body_lines, body_lines(run))}
  end
```

- [ ] **Step 5: Update `render/2` to render the list when present**

Replace the body `<div>` in `render/2` with a branch on `@body_lines`:

```elixir
      <div class="text-sm text-[color:var(--ink)]">
        <ul :if={@body_lines} class="space-y-1">
          <li :for={line <- @body_lines} class="flex gap-2">
            <span class="text-[color:var(--subtle)]">·</span>
            <span>{line}</span>
          </li>
        </ul>
        <span :if={is_nil(@body_lines)}>{Phoenix.HTML.raw(@body_html)}</span>
      </div>
```

- [ ] **Step 6: Add `body_lines/1`, `applied_lines/1`, `line_for/1`, `day_name/1`, `day_of/1`; remove the dead Applied body path**

In `lib/tore_web/components/receipt_live.ex`:

1. Remove the `defp body(%State.Applied{...})` clause (the Applied body now goes through `body_lines/1`).
2. Remove `summary_text/1`.
3. Update aliases: `summary_text/1` was the only user of `alias Tore.Harness.Artifact` and `alias Tore.Harness.Artifact.RunSummary`; remove both, and add `alias Tore.Harness.Artifact.PlanDiff`. Final alias block:

```elixir
  alias Tore.Harness.Run.State
  alias Tore.Harness.Artifact.PlanDiff
```

4. Add `body_lines/1` (returns a list for Applied, nil otherwise) and helpers:

```elixir
  # Applied runs render a list of per-change lines; other variants use body/1.
  defp body_lines(%State.Applied{} = run), do: applied_lines(run)
  defp body_lines(_), do: nil

  defp applied_lines(%State.Applied{artifacts: artifacts}) do
    case Enum.find(artifacts, &match?(%PlanDiff{}, &1)) do
      %PlanDiff{} = diff ->
        case PlanDiff.summarise(diff) do
          [] -> [gettext("No changes")]
          rollup -> Enum.map(rollup, &line_for/1)
        end

      nil ->
        [gettext("No changes")]
    end
  end

  defp line_for(%{change: :added, label: label, slot_key: sk}) when is_binary(label) and label != "",
    do: gettext("Added %{recipe} on %{day}", recipe: label, day: day_of(sk))

  defp line_for(%{change: :added, slot_key: sk}),
    do: gettext("Added a meal on %{day}", day: day_of(sk))

  defp line_for(%{change: :swapped, label: label, slot_key: sk}) when is_binary(label) and label != "",
    do: gettext("Swapped in %{recipe} on %{day}", recipe: label, day: day_of(sk))

  defp line_for(%{change: :swapped, slot_key: sk}),
    do: gettext("Swapped %{day}", day: day_of(sk))

  defp line_for(%{change: :skipped, slot_key: sk}),
    do: gettext("Skipped %{day}", day: day_of(sk))

  defp line_for(%{change: :removed, slot_key: sk}),
    do: gettext("Cleared %{day}", day: day_of(sk))

  defp line_for(%{change: :leftover, slot_key: sk}),
    do: gettext("Leftovers on %{day}", day: day_of(sk))

  defp line_for(%{change: :servings, slot_key: sk}),
    do: gettext("Adjusted servings on %{day}", day: day_of(sk))

  defp day_of(slot_key), do: slot_key |> String.split("_", parts: 2) |> hd() |> day_name()

  defp day_name("mon"), do: gettext("Monday")
  defp day_name("tue"), do: gettext("Tuesday")
  defp day_name("wed"), do: gettext("Wednesday")
  defp day_name("thu"), do: gettext("Thursday")
  defp day_name("fri"), do: gettext("Friday")
  defp day_name("sat"), do: gettext("Saturday")
  defp day_name("sun"), do: gettext("Sunday")
  defp day_name(other), do: String.capitalize(other)
```

Note the `line_for/1` clause ORDER matters: the `:added`/`:swapped` with-label (guarded) clauses must come BEFORE their no-label counterparts so a present label wins. Keep them in the order shown.

- [ ] **Step 7: Update the pre-existing Applied test**

The existing test `"renders summary for Applied with header text"` builds a PlanDiff with `events: [%{slot_key: "mon", event_type: "MealSkipped", payload: %{}, rationale: ["x"]}]` and asserts:

```elixir
    assert html =~ "Tore adjusted the plan"
    assert html =~ "skipped"
```

The header assertion still holds. The body is now the line `gettext("Skipped %{day}", day: "Monday")` → "Skipped Monday", so the lowercase `"skipped"` assertion FAILS. Change that one line to:

```elixir
    assert html =~ "Skipped"
    assert html =~ "Monday"
```

(`day_of("mon")` splits on `_`, gets `"mon"`, → `day_name("mon")` → "Monday".) Do NOT delete or otherwise weaken the test.

- [ ] **Step 8: Run tests to verify they pass**

Run: `mix test test/tore_web/components/receipt_live_test.exs`
Expected: PASS (new tests + the adjusted existing ones).

- [ ] **Step 9: Compile clean (no unused alias)**

Run: `mix compile --warnings-as-errors 2>&1 | tail -5`
Expected: clean — confirms `Artifact`/`RunSummary` aliases were removed (else unused-alias warning) and `PlanDiff` is used.

- [ ] **Step 10: Commit**

```bash
jj describe -m "feat(web): receipt lists named per-change lines from PlanDiff"
jj new
```

---

## Task 2: Verification sweep

**Files:** none (verification only).

- [ ] **Step 1: Run the web component + planner live suites**

Run: `mix test test/tore_web/components/receipt_live_test.exs test/tore_web/live/planner_live_test.exs`
Expected: 0 failures.

- [ ] **Step 2: Full suite floor check**

Run: `mix test 2>&1 | tail -4`
Expected: failures only in `Tore.Groceries.*` / `GroceriesHandlerTest` (the known floor). No new failures.

- [ ] **Step 3: Compile force-clean**

Run: `mix compile --force --warnings-as-errors 2>&1 | tail -3`
Expected: clean.

- [ ] **Step 4: Manual smoke (user-run; agent must NOT handle the OPENROUTER_API_KEY)**

Ask the user to restart the server cold (`OPENROUTER_API_KEY=… iex -S mix phx.server` — a full restart, not `recompile()`, since the dev box has no inotify watcher), open `/plan`, and run a multi-action command (e.g. `swap tuesday and saturday recipes and skip sunday`). Expect the receipt to show one named line per change — a "Swapped in <recipe> on …" line and a "Skipped …" line — in the household locale.

- [ ] **Step 5: Final commit**

```bash
jj describe -m "test(web): named receipt lines pass sweep + manual smoke"
jj new
```

---

## Self-Review Notes

**Spec coverage:**
- Data path (receipt reads PlanDiff.summarise) → Task 1 Step 6 `applied_lines/1`.
- Rendering shape (list of lines) → Task 1 Steps 4–5.
- Per-change wording table + nil-label fallback → Task 1 Step 6 `line_for/1` clauses.
- Day name localization → `day_name/1`/`day_of/1`.
- Empty / no-PlanDiff → "No changes" line.
- Non-Applied variants unchanged → `body_lines/1` returns nil for them; `body/1` Applied clause removed, others untouched.
- gettext throughout → every `line_for`/`day_name` string.
- Testing + success criteria → Task 1 tests + Task 2.

**Type consistency:** `applied_lines/1` and `line_for/1` consume the
`%{slot_key, change, label, ...}` map shape that `PlanDiff.summarise/1` returns.
`body_lines/1` returns `[String.t()]` for Applied, `nil` otherwise; `render/2`
branches on `@body_lines` being a list vs nil. Alias block reduced to `State` +
`PlanDiff` (the only modules referenced after removing `summary_text/1`).

**Locale caveat:** per the spec, this plan makes the lines localizable (all
gettext) but does NOT wire `Gettext.put_locale` at mount — out of scope.
