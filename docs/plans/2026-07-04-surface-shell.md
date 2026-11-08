# Surface Shell Implementation Plan (Plan 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reshape the app shell to the surface-consolidation design — 3-tab nav + command pill, Capture as a slide-up sheet, week strip removed from Today, review pill on Today, Settings as the home of Run history — without touching the harness.

**Architecture:** Pure presentation-layer changes over the existing backend. Navigation shrinks from 9 entity-shaped items to Today/Plan/Shop plus a center command pill. `/capture`, `/inbox`, `/runs/:id` stay routable (deep links) but leave the nav; Capture presents as a sheet via slide-up transition on navigation. The review pill on Today reuses the existing pending-runs count that today feeds the inbox nav badge.

**Tech Stack:** Phoenix LiveView, HEEx function components, `Phoenix.LiveViewTest`, Tailwind (CSS-variable tokens), jj for VCS.

**Source spec:** `docs/specs/2026-07-04-surface-consolidation-design.md` §1, §2, §4 (tray skeleton only), §5 (pill + Settings entry only), §6, §9. Object sheets (§4.1) are Plan 2; the anticipation layer (§3) and receipt seen-state are Plan 3.

**Conventions for every task:** run tests with `mix test <path>`; commit with `jj describe -m "<msg>" && jj new`. Test auth setup: copy the `setup` / login-helper pattern from `test/tore_web/live/home_live_test.exs` — all authenticated LiveView tests in this repo bootstrap the same way. All user-facing strings go through `gettext`.

---

### Task 1: Commit the in-flight tidy edits

The working copy holds three cosmetic leftovers from the previous session
(helper-clause moves in `lib/tore/harness/run.ex` and
`lib/tore/harness/run_receipts.ex`, a dead `store_pct(_, [])` clause removed
in `lib/tore_web/live/cost_live.ex`). They are complete and harmless; land
them so Plan 1 starts from a clean working copy.

**Files:**

- Modify: none (already modified in working copy)

- [ ] **Step 1: Verify the diff is only the three tidy files**

Run: `jj diff --stat`
Expected: exactly `lib/tore/harness/run.ex`, `lib/tore/harness/run_receipts.ex`, `lib/tore_web/live/cost_live.ex`.

- [ ] **Step 2: Run the affected tests**

Run: `mix test test/tore/harness test/tore_web/live`
Expected: PASS (these are no-op refactors).

- [ ] **Step 3: Commit**

```bash
jj describe -m "chore: tidy helper placement in run/run_receipts, drop dead store_pct clause"
jj new
```

---

### Task 2: Shrink the nav to Today · Plan · Shop

**Files:**

- Modify: `lib/tore_web/components/layouts.ex:9-21` (nav_items), `:50-58` (mobile bar), `:64-66` (badge_for)
- Test: `test/tore_web/components/layouts_test.exs` (create) or extend `test/tore_web/live/home_live_test.exs`

- [ ] **Step 1: Write the failing test** (in `test/tore_web/live/home_live_test.exs`)

```elixir
describe "app shell nav" do
  test "shows only Today, Plan, Shop as destinations", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(href="/plan")
    assert html =~ ~s(href="/shop")
    refute html =~ ~s(href="/recipes")
    refute html =~ ~s(href="/prep")
    refute html =~ ~s(href="/deals")
    refute html =~ ~s(href="/inbox")
    refute html =~ ~s(href="/cooking")
  end
end
```

(Reuse the file's existing authenticated `setup`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore_web/live/home_live_test.exs`
Expected: FAIL on the `refute` lines (all nine links currently render).

- [ ] **Step 3: Cut nav_items to three and drop the inbox badge**

In `lib/tore_web/components/layouts.ex` replace `nav_items/0`:

```elixir
defp nav_items do
  [
    {"/", gettext("Today"), "nav-home"},
    {"/plan", gettext("Plan"), "nav-week"},
    {"/shop", gettext("Shop"), "nav-shop"}
  ]
end
```

Desktop header (`def app`, line 33-44): append a Settings link after the
loop so Settings stays reachable on desktop:

```heex
<.nav_link
  path="/settings"
  current={@current_path}
  icon="nav-settings"
  label={gettext("Settings")}
  badge={nil}
/>
```

Mobile bar (line 50): change `grid-cols-10` to `grid-cols-4` (Today, Plan,
pill placeholder, Shop — the pill lands in Task 3; temporarily render the
three links in a `grid-cols-3`). Delete `badge_for/2` (lines 64-66) and the
`badge={badge_for(...)}` arguments — the red inbox badge is retired (the
review pill replaces it in Task 5). Keep the `:inbox_count` attr for now;
Task 5 consumes it in HomeLive instead.

- [ ] **Step 4: Run the test and full LiveView suite**

Run: `mix test test/tore_web/live/home_live_test.exs && mix test test/tore_web`
Expected: PASS. If other tests asserted on removed nav links, fix those
assertions — the links are gone by design.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(shell): shrink nav to Today/Plan/Shop, retire inbox badge"
jj new
```

---

### Task 3: Command pill + Capture as slide-up sheet

**Files:**

- Modify: `lib/tore_web/components/layouts.ex` (pill in the mobile bar center slot + desktop header entry)
- Modify: `lib/tore_web/live/capture_live.ex:97` (render/1 — sheet chrome)
- Test: `test/tore_web/live/home_live_test.exs`, `test/tore_web/live/capture_live_test.exs`

- [ ] **Step 1: Write the failing tests**

In `home_live_test.exs`:

```elixir
test "renders the command pill linking to capture", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/")
  assert html =~ ~s(data-role="command-pill")
  assert html =~ ~s(href="/capture")
end
```

In `capture_live_test.exs`:

```elixir
test "capture renders as a sheet with a close affordance", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/capture")
  assert html =~ ~s(data-role="command-tray")
  assert html =~ ~s(aria-label="Close")
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tore_web/live/home_live_test.exs test/tore_web/live/capture_live_test.exs`
Expected: FAIL — `data-role` attributes don't exist yet.

- [ ] **Step 3: Add the pill to the shell**

In `layouts.ex`, mobile bar becomes `grid-cols-4` with the pill in slot 3
(between Plan and Shop). Insert into the `<nav class="md:hidden ...">` body,
after the Plan `bottom_link` (order the loop manually — replace the `:for`
comprehension with three explicit `<.bottom_link>` calls so the pill can sit
third):

```heex
<.bottom_link path="/" current={@current_path} icon="nav-home" />
<.bottom_link path="/plan" current={@current_path} icon="nav-week" />
<a
  href="/capture"
  data-role="command-pill"
  aria-label={gettext("Open command tray")}
  class="flex items-center justify-center h-14"
>
  <span class="w-12 h-7 rounded-full border border-[color:var(--border)] bg-[var(--bg)] flex items-center justify-center">
    <span class="w-5 h-1 rounded-full bg-[color:var(--muted)]"></span>
  </span>
</a>
<.bottom_link path="/shop" current={@current_path} icon="nav-shop" />
```

Design constraints (spec §4 "Not a support widget"): no sparkle/robot icon,
no label, no animation, no badge — the pill is a neutral grabber shape in
the bar's structure. Desktop: add the same link as a `nav_link`-style entry
in the header with icon `nav-capture` if that icon exists in
`core_components.ex`'s icon set; otherwise reuse the grabber shape.

- [ ] **Step 4: Give CaptureLive sheet chrome**

In `capture_live.ex` `render/1`, wrap the existing content in a sheet
container and add a close affordance at top:

```heex
<div
  id="command-tray"
  data-role="command-tray"
  phx-mounted={JS.transition({"transition-transform duration-200 ease-out", "translate-y-full", "translate-y-0"})}
  class="fixed inset-x-0 bottom-0 top-8 z-50 rounded-t-2xl bg-[var(--surface)] border-t border-[color:var(--border)] overflow-y-auto"
>
  <div class="sticky top-0 flex justify-center py-2 bg-[var(--surface)]">
    <.link navigate={@return_to || ~p"/"} aria-label={gettext("Close")}>
      <span class="w-10 h-1.5 rounded-full bg-[color:var(--border)] block"></span>
    </.link>
  </div>
  <%!-- existing capture content, unchanged --%>
</div>
```

Add `@return_to` to mount from `params["return_to"]` (default `nil`), and
make the pill link pass it: `href={"/capture?return_to=#{@current_path}"}`
in the layout (add `@current_path` interpolation). Respect reduced motion:
the `JS.transition` classes are `motion-safe:` prefixed if the app's
Tailwind config doesn't already gate transitions.

- [ ] **Step 5: Run tests**

Run: `mix test test/tore_web/live/home_live_test.exs test/tore_web/live/capture_live_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(shell): command pill in bottom bar; capture presents as slide-up sheet"
jj new
```

---

### Task 4: Remove the week strip from Today

**Files:**

- Modify: `lib/tore_web/live/home_live.ex:101` (call site), `:170` (component defn), plus whatever assigns feed only the strip (trace from the component's attrs)
- Test: `test/tore_web/live/home_live_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
test "today does not render the week strip", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/")
  refute html =~ "week-strip"
end
```

(Confirm the component's rendered class/id first — `home_live.ex:170`
defines `week_strip/1`; use whatever stable attribute its root element has,
adding `data-role="week-strip"` first if it has none, then asserting on
that.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore_web/live/home_live_test.exs`
Expected: FAIL (strip renders today).

- [ ] **Step 3: Delete the strip**

Remove the `<.week_strip ...>` call at `home_live.ex:101` and the
`week_strip/1` component at `:170`. Delete any `mount`/`handle_params`
assigns that only the strip consumed (follow the attrs it took; typically a
`@week` summary — keep anything the Tomorrow card also uses). Do not remove
the Tomorrow card.

- [ ] **Step 4: Run the file's full test suite**

Run: `mix test test/tore_web/live/home_live_test.exs`
Expected: PASS, including any pre-existing tests that referenced the strip
(update them to the new expectation — the strip is gone by design).

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(today): remove week strip; the week lives on Plan"
jj new
```

---

### Task 5: Review pill on Today

**Files:**

- Modify: `lib/tore_web/live/home_live.ex` (render the pill from the pending-runs count)
- Modify: `lib/tore_web/components/layouts.ex` (drop the now-unused `:inbox_count` attr once nothing passes it)
- Test: `test/tore_web/live/home_live_test.exs`

The count already exists — it fed the old inbox nav badge (`layouts.ex`
`inbox_count` assign). Find its source (grep `inbox_count` in
`lib/tore_web/`) and reuse the same query in HomeLive's mount.

- [ ] **Step 1: Write the failing tests**

```elixir
test "review pill shows when runs need attention", %{conn: conn} do
  # Use the same fixture the inbox tests use to create a :needs_user run
  # (see test/tore_web/live/ for the inbox/run_review test setup helpers).
  create_needs_user_run_fixture()

  {:ok, _view, html} = live(conn, ~p"/")
  assert html =~ ~s(data-role="review-pill")
  assert html =~ "1"
end

test "review pill is absent when nothing needs review", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/")
  refute html =~ ~s(data-role="review-pill")
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/tore_web/live/home_live_test.exs`
Expected: FAIL.

- [ ] **Step 3: Render the pill**

In HomeLive's render, after the counter-note slot:

```heex
<.link
  :if={@review_count > 0}
  navigate={~p"/inbox"}
  data-role="review-pill"
  class="inline-flex items-center gap-2 px-4 h-9 rounded-full border border-[color:var(--border)] bg-[var(--surface)] text-sm text-[var(--text)]"
>
  {ngettext("%{count} to review", "%{count} to review", @review_count, count: @review_count)}
</.link>
```

Assign `@review_count` in mount from the same context call that produced
`inbox_count`. Rules from the design spec §5: no red, no badge styling, not
rendered at zero. `/inbox` remains the destination the pill opens (it
presents the receipt list; converting it to a true sheet rides Plan 3).

- [ ] **Step 4: Run tests**

Run: `mix test test/tore_web/live/home_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Remove the dead `:inbox_count` plumbing**

If no LiveView passes `inbox_count` to `Layouts.app` anymore, delete the
attr (layouts.ex:26) and every assign that fed it. Run
`grep -rn "inbox_count" lib/tore_web/` — expected: only HomeLive's new
usage (renamed `review_count`) remains.

- [ ] **Step 6: Run the web suite and commit**

Run: `mix test test/tore_web`
Expected: PASS.

```bash
jj describe -m "feat(today): review pill replaces inbox nav badge"
jj new
```

---

### Task 6: Settings gains Run history; flat sections

**Files:**

- Modify: `lib/tore_web/live/settings_live.ex` (add Run history entry beside the existing Pantry/Spending entries at :362-371)
- Test: `test/tore_web/live/settings_live_test.exs` (create if missing, following `home_live_test.exs` setup)

- [ ] **Step 1: Write the failing test**

```elixir
test "settings links to run history", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/settings")
  assert html =~ ~s(href="/inbox")
  assert html =~ "Run history"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/tore_web/live/settings_live_test.exs`
Expected: FAIL.

- [ ] **Step 3: Add the section entry**

Next to the existing Pantry (`settings_live.ex:362`) and Spending (`:371`)
navigation entries, add a Run history entry in the same visual style
(match the sibling markup exactly — same component or classes):

```heex
<.link navigate={~p"/inbox"} class={/* same classes as the pantry entry */}>
  {gettext("Run history")}
  <span class="text-sm text-[color:var(--muted)]">
    {gettext("Everything Tore has done, and how to undo it")}
  </span>
</.link>
```

- [ ] **Step 4: Run tests and commit**

Run: `mix test test/tore_web/live/settings_live_test.exs`
Expected: PASS.

```bash
jj describe -m "feat(settings): run history entry; inbox reachable from settings only"
jj new
```

---

### Task 7: Amend docs/specs/ui.md and close out

**Files:**

- Modify: `docs/specs/ui.md` §3.1-3.3 (nav + route map), §6.1 (Today: strip removed, review pill added, rules line), §6.7 (Run history section)

- [ ] **Step 1: Update docs/specs/ui.md to match shipped reality**

- §3.1: four destinations → three tabs + command pill (paste the bar diagram from the design doc §1).
- §3.2: route map — `/groceries` → `/shop` (already true in code), remove `/settings/*` sub-route claims only if Task 6 changed them (it did not — leave for Plan 3), annotate `/capture`, `/inbox`, `/runs/:id` as "routable, presented as layers, not in nav".
- §6.1: delete the Week strip block (lines under "### Week strip"), add the review pill to the Secondary list, and append to Rules: `Today must not duplicate the week — that is Plan.`
- §6.7: add `Run history` to the Sections list.

- [ ] **Step 2: Verify the whole suite one final time**

Run: `mix test`
Expected: PASS (full suite green).

- [ ] **Step 3: Commit and push**

```bash
jj describe -m "docs(ui-spec): sync nav, Today, Settings with surface shell"
jj new
jj bookmark move master --to @-
jj git push -b master
```

---

## Deferred to later plans

- **Plan 2 — Object sheets + resolved handles:** SPEC.md §A.6.2 resolvers/
  handles in the harness, `source: :direct_touch` (design §4.1 + SPEC
  amendment #5), scoped input on slot sheets, planner tools moving from raw
  IDs to handles.
- **Plan 3 — Anticipation layer:** `:ambient_scan_run` + `CounterNoteVerifier`,
  new CounterNote kinds + scan re-triggers (SPEC amendments #3/#4), tray
  half-state predictions, receipt seen-state (#2), true sheet presentation
  for `/inbox` + `/runs/:id`, Settings full flattening (pantry/costs as
  in-page sections), deal product identity (#1) with `DealsDigestCapsule`.
