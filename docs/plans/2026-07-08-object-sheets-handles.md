# Object Sheets + Resolved Handles Implementation Plan (Plan 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The LLM stops passing raw recipe IDs to action tools — it passes handles minted by resolvers or by the user's touch. The plan slot sheet gains a scoped input whose referent is pre-resolved (`source: :direct_touch`, confidence 1.0), deleting the reference-ambiguity failure mode for slot-scoped commands.

**Architecture:** Handles are structs with an opaque `ref` token. The `PlannerAgent` runtime keeps a per-run handle registry: read tools that surface recipes (search, resolve) mint handles which the runtime registers; action tools accept `recipe_ref` strings which the runtime exchanges for the registered handle *before* invoking the tool's `run` — an unknown ref is rejected back to the model as a tool error. Tool `run` functions stay pure and keep receiving real ids. The slot sheet's scoped input dispatches a `:planner_command_run` whose input carries a pre-registered direct-touch slot handle.

**Tech Stack:** Elixir/Phoenix LiveView, ExUnit + Mox (`Tore.MockLLM`), existing Decider harness. jj for VCS (controller only).

**Source specs:** SPEC.md §A.6.2; design doc `docs/specs/2026-07-04-surface-consolidation-design.md` §4.1 + §10 amendment 5.

---

## Process rules (proven in Plan 1 — binding)

- Implementers/reviewers run **no git and no jj commands, ever**. All changes accumulate in the working copy; the controller makes one commit at the end.
- `mix test` sparingly: red check, green check, one final sweep per task. On `failed to acquire filesystem lock using TCP, reason: :eperm`, rerun the identical command with the sandbox bypass (environmental).
- Inspect state via Read/grep only.

## Scope decisions (locked during planning — do not relitigate in tasks)

1. **Recipes get the full handle treatment.** Raw integer `recipe_id` is the hallucination-prone reference. `assign_recipe` switches to `recipe_ref`.
2. **Slots keep structural `slot_key` strings in tools.** `"mon_dinner"` keys are enumerable, semantically meaningful, and handed to the model in its context — they are domain keys, not DB ids. The natural-language `resolve_slot` tool is **deferred**; the object sheet covers the "which slot did you mean" case with certainty instead.
3. **`search_recipes` becomes a resolver source** (SPEC's example handle literally shows `source: :search_recipes`): its results carry refs. A dedicated `resolve_recipe` fuzzy tool joins it.
4. **Deferred to later plans:** `resolve_grocery_item`, `resolve_pantry_item` (no consumer until the reconciliation run exists), long-press object sheets on the tonight card and grocery rows (needs a JS hook; Plan 3), `run_kinds.ex` static declarations.

---

### Task 1: `Tore.Harness.Handles`

**Files:**

- Create: `lib/tore/harness/handles.ex`
- Test: `test/tore/harness/handles_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Tore.Harness.HandlesTest do
  use ExUnit.Case, async: true

  alias Tore.Harness.Handles
  alias Tore.Harness.Handles.{ResolvedRecipe, ResolvedSlot}

  test "recipe/4 mints a handle with a rcp_ ref and clamped confidence" do
    h = Handles.recipe(42, "Salmon pasta", :search_recipes, 0.91)
    assert %ResolvedRecipe{id: 42, label: "Salmon pasta", source: :search_recipes} = h
    assert h.confidence == 0.91
    assert String.starts_with?(h.ref, "rcp_")
    refute Handles.recipe(42, "Salmon pasta", :search_recipes, 0.91).ref == h.ref
  end

  test "slot/2 mints a direct-touch handle with confidence 1.0" do
    h = Handles.slot("tue_dinner", "Tuesday dinner")
    assert %ResolvedSlot{slot_key: "tue_dinner", source: :direct_touch, confidence: 1.0} = h
    assert String.starts_with?(h.ref, "slt_")
  end

  test "register/2 and fetch/2 round-trip; unknown ref errors" do
    h = Handles.recipe(1, "A", :resolve_recipe, 0.8)
    reg = Handles.register(%{}, h)
    assert {:ok, ^h} = Handles.fetch(reg, h.ref)
    assert :error = Handles.fetch(reg, "rcp_nope")
    assert :error = Handles.fetch(reg, nil)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/tore/harness/handles_test.exs`
Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement**

```elixir
defmodule Tore.Harness.Handles do
  @moduledoc """
  Resolved references (SPEC.md §A.6.2). A handle carries the resolved id,
  a human label, the resolver that produced it, a confidence, and an opaque
  `ref` token. The LLM only ever sees and repeats `ref`s; the PlannerAgent
  runtime exchanges refs for handles via a per-run registry, so an invented
  or stale ref is rejected before any action tool runs.
  """

  defmodule ResolvedRecipe do
    @enforce_keys [:id, :label, :source, :confidence, :ref]
    defstruct [:id, :label, :source, :confidence, :ref]
  end

  defmodule ResolvedSlot do
    @enforce_keys [:slot_key, :label, :source, :confidence, :ref]
    defstruct [:slot_key, :label, :source, :confidence, :ref]
  end

  def recipe(id, label, source, confidence) do
    %ResolvedRecipe{
      id: id,
      label: label,
      source: source,
      confidence: confidence,
      ref: token("rcp")
    }
  end

  def slot(slot_key, label) do
    %ResolvedSlot{
      slot_key: slot_key,
      label: label,
      source: :direct_touch,
      confidence: 1.0,
      ref: token("slt")
    }
  end

  def register(registry, %{ref: ref} = handle), do: Map.put(registry, ref, handle)

  def fetch(registry, ref) when is_binary(ref), do: Map.fetch(registry, ref)
  def fetch(_registry, _), do: :error

  defp token(prefix),
    do: prefix <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
end
```

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/tore/harness/handles_test.exs`
Expected: PASS (4 tests).

---

### Task 2: `Tore.Harness.Resolvers.resolve_recipe/1`

**Files:**

- Create: `lib/tore/harness/resolvers.ex`
- Test: `test/tore/harness/resolvers_test.exs`

Fuzzy title match over the catalog. Contract:

- `{:ok, %ResolvedRecipe{}}` when one candidate clearly wins (best similarity ≥ 0.7 AND (only match ≥ 0.4 OR best beats runner-up by ≥ 0.1)).
- `{:ambiguous, [%ResolvedRecipe{}]}` (top 3, sorted) when several plausible.
- `:not_found` when best < 0.4.
- `source: :resolve_recipe`, `confidence:` the similarity score.

- [ ] **Step 1: Write the failing tests** (use the repo's DataCase — check how `test/tore/` domain tests set up the sandbox and create recipes; `grep -rn "Recipes.create\|insert" test/tore/ | head` to find the fixture idiom and reuse it)

```elixir
defmodule Tore.Harness.ResolversTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Resolvers
  alias Tore.Harness.Handles.ResolvedRecipe

  # create three recipes via the existing fixture idiom:
  #   "Salmon pasta", "Salmon soup", "Chicken skewers"

  test "exact-ish title resolves with high confidence" do
    assert {:ok, %ResolvedRecipe{label: "Chicken skewers", source: :resolve_recipe} = h} =
             Resolvers.resolve_recipe("chicken skewers")

    assert h.confidence > 0.9
  end

  test "shared prefix is ambiguous" do
    assert {:ambiguous, handles} = Resolvers.resolve_recipe("salmon")
    assert length(handles) == 2
    assert Enum.all?(handles, &match?(%ResolvedRecipe{}, &1))
  end

  test "garbage is not found" do
    assert :not_found = Resolvers.resolve_recipe("zzzz qqqq")
  end
end
```

- [ ] **Step 2: Run to verify failure**, then **Step 3: Implement**

```elixir
defmodule Tore.Harness.Resolvers do
  @moduledoc """
  Resolver tools (SPEC.md §A.6.2): natural-language reference → typed handle.
  V1 implements recipes only; slot references are covered by structural
  slot keys and direct-touch handles. Pure read — no writes, no LLM calls.
  """

  alias Tore.Harness.Handles
  alias Tore.Recipes

  @accept 0.7
  @floor 0.4
  @clear_gap 0.1

  def resolve_recipe(query) when is_binary(query) do
    q = normalize(query)

    scored =
      Recipes.list()
      |> Enum.map(fn r -> {similarity(q, normalize(r.title)), r} end)
      |> Enum.sort_by(fn {s, _} -> s end, :desc)

    case scored do
      [] -> :not_found
      [{best, _} | _] when best < @floor -> :not_found
      [{best, r}] when best >= @accept -> {:ok, to_handle(r, best)}
      [{best, r}, {second, _} | _] when best >= @accept and best - second >= @clear_gap ->
        {:ok, to_handle(r, best)}
      plausible ->
        {:ambiguous,
         plausible
         |> Enum.take_while(fn {s, _} -> s >= @floor end)
         |> Enum.take(3)
         |> Enum.map(fn {s, r} -> to_handle(r, s) end)}
    end
  end

  defp to_handle(recipe, score),
    do: Handles.recipe(recipe.id, recipe.title, :resolve_recipe, Float.round(score, 2))

  defp similarity(a, b) do
    jaro = String.jaro_distance(a, b)
    # a query that is a whole word of the title should stay plausible
    if String.contains?(b, a), do: max(jaro, 0.65), else: jaro
  end

  defp normalize(s), do: s |> String.downcase() |> String.trim()
end
```

Tune the constants against the tests — if "salmon" vs "Salmon pasta"/"Salmon soup" doesn't land in the ambiguous branch with these values, adjust `@floor`/the `contains` boost until the three tests express the contract, and note the final values in your report. The tests are the spec; the constants are implementation.

- [ ] **Step 4: Run to verify pass**

Run: `mix test test/tore/harness/resolvers_test.exs`
Expected: PASS (3 tests).

---

### Task 3: Handle enforcement in the agent runtime + tool migration

**Files:**

- Modify: `lib/tore/llm/planner_agent.ex` (state gains `handles: %{}`; ref exchange + registration in `handle_tool`)
- Modify: `lib/tore/llm/planner_tools.ex` (`assign_recipe` takes `recipe_ref`; `search_recipes` results carry refs + handles; new `resolve_recipe` read tool)
- Modify: `lib/tore/harness/orchestrator.ex` (planner instructions: resolve-then-act)
- Test: `test/tore/llm/planner_agent_test.exs`, `test/tore/llm/planner_tools_test.exs`

Read all three lib files and both test files fully before editing — the loop's
`handle_tool/4`, the `{:ok, result, events, plan}` tool contract, and the
existing Mox patterns are the ground you build on.

**Design (follow exactly):**

- `PlannerAgent.run/4` initial state gains `handles: Map.get(ctx, :handles, %{})` — pre-seeded handles (the object sheet's direct-touch slot in Task 4) enter here.
- **Read-tool registration:** when a tool result contains handles, the runtime registers them. Convention: a tool's `run` may return `{:ok, result, handles_list, events, plan}`... do NOT invent a 5-tuple — instead keep the 4-tuple contract and put handles in the result map under a reserved key: `%{..., __handles__: [handle]}`. After a successful tool call, `handle_tool` pops `:__handles__` from the result, registers each into `state.handles`, and strips the key before the result is JSON-encoded back to the model (the model sees each item's `ref` and `label` in the normal result payload, never the struct).
- **Action-ref exchange:** before invoking an action tool whose parameters include `recipe_ref`, the runtime does `Handles.fetch(state.handles, args["recipe_ref"])`. On `{:ok, handle}` it injects `args = Map.put(args, "recipe_id", handle.id)` and proceeds (tool `run` bodies keep using `args["recipe_id"]`). On `:error` it does NOT invoke `run`; it feeds a tool error back to the model: `"unknown recipe_ref %{ref} — call search_recipes or resolve_recipe first and use a ref from the result"` (mirror how invalid-args errors are already fed back; find that path in planner_agent.ex and reuse it). The rejected call still counts toward `max_action_calls`.
- **`search_recipes`:** each result entry gains `"ref"` (mint via `Handles.recipe(id, title, :search_recipes, 1.0)` — exact catalog rows, full confidence) and the run result carries `__handles__`. Keep existing fields so prompts/tests relying on titles survive.
- **New `resolve_recipe` read tool:** parameters `%{query: %{type: "string"}}`, required `["query"]`. Runs `Tore.Harness.Resolvers.resolve_recipe/1`; maps `{:ok, h}` → `%{match: %{ref: h.ref, label: h.label, confidence: h.confidence}, __handles__: [h]}`; `{:ambiguous, hs}` → `%{ambiguous: [%{ref:, label:, confidence:} ...], note: "multiple matches — ask_user or refine", __handles__: hs}`; `:not_found` → `%{not_found: true}`.
- **`assign_recipe`:** parameter schema swaps `recipe_id: %{type: "integer"}` for `recipe_ref: %{type: "string", description: "a ref returned by search_recipes or resolve_recipe"}`; required list updates; the `run` body is unchanged except it reads the injected `args["recipe_id"]`.
- **Orchestrator instructions** (the planner system-prompt text around `orchestrator.ex:868`): replace any "use recipe ids" phrasing with: recipes are referenced by `ref` obtained from `search_recipes`/`resolve_recipe`; on ambiguity call `ask_user`, never guess.

- [ ] **Step 1: Write the failing tests** (extend both test files; follow their existing Mox `Tore.MockLLM` + tool-call fabrication patterns exactly)

planner_agent_test.exs additions:

```elixir
test "action tool with an invented recipe_ref is rejected and fed back" do
  # Mock LLM turn 1: tool_call assign_recipe(slot_key: "mon_dinner", recipe_ref: "rcp_fake", ...)
  # Mock LLM turn 2 (receives the tool error): plain message "ok"
  # Assert: no plan_events produced; the tool_result trace step for the call
  # contains "unknown recipe_ref"; loop terminated normally.
end

test "search then assign via returned ref applies the command" do
  # Mock LLM turn 1: tool_call search_recipes(query: ...)
  # From the tool_result payload the test extracts the first result's "ref"
  #   (the mock LLM can't read it, so drive turn 2 with a captured ref via
  #   the messages the agent sends — follow how existing multi-turn tests
  #   thread state; if they hardcode, fabricate turn 2 after inspecting
  #   state via the returned tool_trace instead and assert on plan_events).
  # Assert: outcome.plan_events contains a RecipeAssigned (or the repo's
  #   actual event) with the real recipe id.
end
```

planner_tools_test.exs additions: `resolve_recipe` tool maps all three resolver outcomes; `search_recipes` results carry `"ref"` strings and `__handles__`; `assign_recipe` schema requires `recipe_ref` and no longer accepts `recipe_id`.

If the existing multi-turn mock pattern cannot thread a dynamically minted ref through the second LLM turn, say so in your report and instead unit-test the ref-exchange seam directly (a thin public wrapper or a well-scoped private-via-public test through `run/4` with a pre-seeded `ctx.handles`) — do not weaken the assertion to "no crash".

- [ ] **Step 2: Run both files, verify the new tests fail**
- [ ] **Step 3: Implement per the design above**
- [ ] **Step 4: Run** `mix test test/tore/llm` **then** `mix test test/tore` — all green. Fix any test that asserted the old `recipe_id` schema.

---

### Task 4: Scoped input on the plan slot sheet

**Files:**

- Modify: `lib/tore_web/live/planner_live.ex` (slot_modal ~line 721; new `handle_event("slot_command", ...)`; dispatch plumbing — read how `handle_event("quick_command", ...)` at ~line 232 dispatches `:planner_command_run` and mirror it)
- Modify: `lib/tore/harness/orchestrator.ex` (`:planner_command_run` input accepts optional `scoped_slot`; pre-seeds `ctx.handles` and prefixes the user text)
- Test: `test/tore_web/live/planner_live_test.exs`

- [ ] **Step 1: Write the failing test** (follow the file's existing setup and however quick_command is currently tested — if quick_command tests mock the orchestrator/LLM, reuse that seam)

```elixir
test "slot sheet scoped command dispatches a run scoped to the touched slot", %{conn: conn} do
  {:ok, view, _} = live(conn, ~p"/plan")
  view |> element(~s([phx-click="open_slot"][phx-value-slot_key="mon_dinner"])) |> render_click()
  # exact selector: read the slot card markup first; adapt to the real attrs

  view
  |> form(~s(form[phx-submit="slot_command"]), %{command: "make it vegetarian"})
  |> render_submit()

  # Assert via the same seam quick_command tests use (mock LLM expectation /
  # run receipt appearing / flash). The load-bearing assertion: the dispatched
  # input carried scoped_slot: "mon_dinner".
end
```

- [ ] **Step 2: Verify it fails.**

- [ ] **Step 3: Implement.**

In `slot_modal`, below the existing actions, one quiet form (match the modal's existing input styling):

```heex
<form phx-submit="slot_command" class="mt-4">
  <input
    type="text"
    name="command"
    autocomplete="off"
    placeholder={gettext("Anything about this day…")}
    class={/* same classes as the command bar input — copy them */}
  />
</form>
```

Handler (next to quick_command's):

```elixir
def handle_event("slot_command", %{"command" => command}, socket) when command != "" do
  slot_key = socket.assigns.selected_slot_key  # read the modal's actual assign name
  # mirror quick_command's dispatch exactly, adding scoped_slot to the input map
  ...
end

def handle_event("slot_command", _params, socket), do: {:noreply, socket}
```

In the orchestrator's `:planner_command_run` dispatch: when `ctx.input[:scoped_slot]` is present, (a) mint `handle = Tore.Harness.Handles.slot(slot_key, humanized_label)` and pass `handles: Handles.register(%{}, handle)` into the agent ctx, (b) prefix the user text with `"[The user is referring to #{humanized_label} (slot #{slot_key}).] "`, (c) record `scoped_slot` in the run's `input` map (it already persists input — verify). Humanize via the existing slot-label helper if one exists (grep `"dinner"` formatting in planner_live/capsules); otherwise `String.replace(slot_key, "_", " ")`.

- [ ] **Step 4: Run** `mix test test/tore_web/live/planner_live_test.exs` then `mix test test/tore_web` — green. Run `mix gettext.extract --merge`; add sv translation for the placeholder (suggest: `"Något om den här dagen…"`).

---

### Task 5: Spec amendments

**Files:**

- Modify: `SPEC.md` §A.6.2, §Status
- Modify: `docs/specs/ui.md` §6.2 (slot sheet)
- Modify: `docs/specs/2026-07-04-surface-consolidation-design.md` (mark §4.1 shipped-for-slots)

- [ ] **Step 1: SPEC.md §A.6.2** — add after the handle example: the `ref` token + per-run registry mechanics (LLM sees refs, runtime exchanges, invented refs rejected as tool errors); add `:direct_touch` to the possible `source` values with confidence 1.0 semantics; add an implementation-status note: V1 ships `resolve_recipe` + direct-touch slot handles; `resolve_slot` (NL), `resolve_grocery_item`, `resolve_pantry_item` deferred until their consumers exist; slot action-tool params remain structural `slot_key` domain keys by design. Add a §Status log entry (dated) recording these decisions.
- [ ] **Step 2: docs/specs/ui.md §6.2** — in the slot sheet/interactions section, add the scoped input: one line of what it is (input inside the slot sheet whose referent is the touched slot, pre-resolved) and the calm rules (placeholder copy, no AI branding).
- [ ] **Step 3: Design doc** — in §4.1 add "Shipped 2026-07 for plan slots (scoped input + direct-touch handles + recipe refs); tonight-card/grocery-row long-press and NL resolve_slot ride Plan 3."
- [ ] **Step 4:** `mix test` full suite once — green.

---

### Task 6: Final review + single commit (controller)

- [ ] Dispatch one independent final reviewer over the whole uncommitted diff (no VCS commands, read-only): handle registry enforcement actually rejects invented refs before `run` executes; no tool schema still accepts `recipe_id` from the model; `__handles__` never leaks into messages sent to the LLM; scoped_slot threads end-to-end; spec edits match shipped code.
- [ ] Fix findings; rerun affected tests.
- [ ] Controller: single `jj describe` + `jj new` + `jj bookmark move master --to @-` + `jj git push -b master`.

---

## Self-review notes (done at planning time)

- Spec coverage: design §4.1 scoped-commands ✅ (Task 4), §10.5 direct-touch ✅ (Tasks 1/4/5), SPEC A.6.2 recipe handles ✅ (Tasks 1-3), deferrals recorded ✅ (Task 5). Long-press extensions explicitly out (header + Task 5).
- Type consistency: `Handles.recipe/4`, `Handles.slot/2`, `Handles.register/2`, `Handles.fetch/2` used identically in Tasks 1-4; `__handles__` reserved key named identically in Tasks 3 and 6.
- The Task 3 multi-turn-mock caveat is a genuine unknown (depends on existing test idioms); the plan names the fallback rather than leaving a TBD.
