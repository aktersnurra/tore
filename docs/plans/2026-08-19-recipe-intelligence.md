# Recipe Intelligence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the planner two new recipe capabilities — find a recipe on the web (discovery only, then scrape the chosen URL) and generate a variant of an existing recipe ("simpler", "vegetarian", "for 6") — both surfacing a `RecipeProposal` the user confirms before anything enters the catalog.

**Architecture:** Both capabilities are planner **read** tools (planner *action* tools are pure in-memory proposals with no IO; these need HTTP/LLM calls, so they cannot be action tools). `find_recipe_web` returns candidate `{title, url}` pairs. `generate_recipe_variant` calls the LLM, builds a `RecipeProposal`, and returns a **loop-terminating** `{:proposal, proposal, pending}` signal that `PlannerAgent` recognises; the orchestrator then verifies the proposal and parks the run in `:needs_user`, reusing the same machinery `receipt_ingestion_run` already uses. On confirm, `commit_recipe_proposal/3` saves the recipe to the catalog and (if a slot was pending) assigns it.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto/SQLite, Mox (`Tore.MockLLM`, `Tore.MockHTTP`), OpenRouter via `Tore.LLM.OpenAI`, jj for version control.

---

## Background the implementer needs

Read these before starting. You do not need to read the whole files, just the named regions.

- **Design spec:** `docs/specs/2026-08-17-recipe-intelligence-design.md`. Decisions D1–D5 are locked; do not redesign.
- **`lib/tore/llm/planner_tools.ex`** — the tool catalog. `all/0` at the top lists every tool. Action tools call `propose/3` (pure, in-memory). Read tools return `{:ok, result_map, [], plan}` — an empty event list and the unchanged plan. A read tool can attach handles by putting `__handles__: [handle]` in its result map; `PlannerAgent` pops that key and registers the handles.
- **`lib/tore/llm/planner_agent.ex`** — the bounded tool loop. `run_and_record/4` is where a tool's return value is interpreted; `finish/2` builds the `loop_outcome` map. Loop-terminating results today are `{:question, q}` (via `ask_user`) and `{:capped, text}`.
- **`lib/tore/harness/orchestrator.ex`** — `dispatch(:planner_command_run, ctx)` at line 42, `run_planner_loop/6` at line 576, `close/4` at ~line 636 (dispatches on `loop.result`), `commit_receipt/4` at line 425 (the model for the new commit function), `discard_run/2` at line 478.
- **`lib/tore/harness/artifact/pantry_snapshot.ex`** — a compact example of the `Tore.Harness.Artifact` behaviour (5 callbacks: `kind/0`, `to_json/1`, `from_json/1`, `summary/1`, `is_rationale_complete/1`).
- **`lib/tore/harness/verifier/cost_entry_verifier.ex`** — the verifier shape: a pure `verify(artifact, ctx)` returning `:ok | {:fail, code, repair_action}`.
- **`lib/tore/recipes.ex`** — `create/1` (line 10) takes `%{title:, ingredients: [...], tags: [...], ...}`; `scrape_from_url/2` (line 100) does fetch + parse + create in one shot and returns `{:ok, %Recipe{}}`.
- **`lib/tore/llm/prompts.ex`** — Pattern-A ops return `{system, user}` tuples (see `extract_recipe/2` at line 163) or a bare system string. `@recipe_schema`, `@recipe_rules`, and `recipe_json_schema/0` (line 136) already define the canonical recipe JSON shape; reuse them. `translation_instruction/1` threads locale — never bake locale-specific examples into the prompt itself.

### Conventions

- **Tests:** `mix test path/to/test.exs:LINE`. `use Tore.DataCase, async: false` for anything touching the Repo or Mox. Mox is set up in `test/support/mocks.ex` (`Tore.MockLLM` for `Tore.LLM.Spec`, `Tore.MockHTTP` for `Tore.HTTP`); `config/test.exs:45` wires `:llm_spec` to `Tore.MockLLM`. Use `import Mox` + `setup :verify_on_exit!`.
- **Known flake:** SQLite "Database busy" under parallel load is pre-existing, not a regression from this work.
- **Commits:** one per task, at the end of the task. Use `jj describe -m "..."` then `jj new`. Trailer on every commit message:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  ```
- **Subagents never run git or jj.** If you are a subagent, stop at the commit step and report that the task is ready to commit; the controller commits.
- **Branching:** work goes to master by default. No PR unless explicitly asked.

---

## File Structure

| File | Responsibility | Status |
|---|---|---|
| `lib/tore/harness/artifact/recipe_proposal.ex` | The artifact: a parsed-or-generated recipe awaiting user confirmation. | Create |
| `lib/tore/harness/artifact/registry.ex` | Register `"RecipeProposal"`. | Modify |
| `lib/tore/harness/verifier/recipe_proposal_verifier.ex` | Deterministic checks on a `RecipeProposal`, including near-duplicate detection. | Create |
| `lib/tore/llm/prompts.ex` | Two new Pattern-A ops: `find_recipe_web/2` and `generate_recipe_variant/3`, plus a web-candidates JSON schema. | Modify |
| `lib/tore/llm/spec.ex` | Add the `web_search/3` callback. | Modify |
| `lib/tore/llm.ex` | Facade delegate for `web_search/3`. | Modify |
| `lib/tore/llm/openai.ex` | Implement `web_search/3` — same body as `text/3` plus the `plugins` key. | Modify |
| `lib/tore/spend_guard.ex` | `:recipe_web_search` feature budget. | Modify |
| `lib/tore/recipes/variant.ex` | Build a `RecipeProposal` from a source recipe + an instruction (the generation LLM call). | Create |
| `lib/tore/llm/planner_tools.ex` | The two new read tools. | Modify |
| `lib/tore/llm/planner_agent.ex` | Recognise `{:proposal, …}` as loop-terminating. | Modify |
| `lib/tore/harness/orchestrator.ex` | `close/4` branch for `{:proposal, …}` → `:needs_user`; `commit_recipe_proposal/3`. | Modify |
| `SPEC.md` | Amendments listed in the design spec. | Modify |

Tests mirror the source tree under `test/`.

---

### Task 1: The `RecipeProposal` artifact

SPEC §A.3 lists this artifact but it was never built. It carries a recipe that does not exist in the catalog yet, plus provenance saying where it came from.

**Files:**

- Create: `lib/tore/harness/artifact/recipe_proposal.ex`
- Modify: `lib/tore/harness/artifact/registry.ex`
- Test: `test/tore/harness/artifact/recipe_proposal_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/tore/harness/artifact/recipe_proposal_test.exs`:

```elixir
defmodule Tore.Harness.Artifact.RecipeProposalTest do
  use ExUnit.Case, async: true

  alias Tore.Harness.Artifact
  alias Tore.Harness.Artifact.RecipeProposal

  defp proposal(overrides \\ %{}) do
    base = %RecipeProposal{
      title: "Miso Ramen",
      description: "A quick weeknight ramen.",
      instructions: "Simmer the broth. Cook the noodles. Assemble.",
      base_servings: 4,
      prep_time_minutes: 10,
      cook_time_minutes: 20,
      ingredients: [
        %{name: "miso paste", quantity: "2", unit: "msk"},
        %{name: "ramen noodles", quantity: "4", unit: "portioner"}
      ],
      tags: ["japanese", "quick"],
      source: :generation,
      source_url: nil,
      source_recipe_id: 7,
      instruction: "make it simpler",
      pending_assignment: %{slot_key: "mon_dinner", servings: 4}
    }

    struct!(base, overrides)
  end

  test "kind/0 is the registered string" do
    assert RecipeProposal.kind() == "RecipeProposal"
  end

  test "round-trips through to_json/from_json" do
    original = proposal()
    round_tripped = RecipeProposal.from_json(RecipeProposal.to_json(original))

    assert round_tripped == original
  end

  test "round-trips a web_import proposal" do
    original =
      proposal(%{
        source: :web_import,
        source_url: "https://example.com/ramen",
        source_recipe_id: nil,
        instruction: nil,
        pending_assignment: nil
      })

    assert RecipeProposal.from_json(RecipeProposal.to_json(original)) == original
  end

  test "round-trips a nil pending_assignment" do
    original = proposal(%{pending_assignment: nil})

    assert RecipeProposal.from_json(RecipeProposal.to_json(original)) == original
  end

  test "summary/1 counts ingredients and falls back to the title" do
    summary = Artifact.summary(proposal())

    assert summary.counts == %{ingredients: 2}
    assert summary.text_fallback == "Miso Ramen"
  end

  test "is_rationale_complete?/1 is true for a generated proposal with an instruction" do
    assert RecipeProposal.is_rationale_complete(proposal())
  end

  test "is_rationale_complete?/1 is false for a generated proposal with no instruction" do
    refute RecipeProposal.is_rationale_complete(proposal(%{instruction: nil}))
  end

  test "is_rationale_complete?/1 is true for a web import with a source url" do
    assert RecipeProposal.is_rationale_complete(
             proposal(%{source: :web_import, source_url: "https://example.com/x", instruction: nil})
           )
  end

  test "Artifact.to_json/1 stamps __kind__" do
    assert %{"__kind__" => "RecipeProposal"} = Artifact.to_json(proposal())
  end

  test "the registry resolves the kind to the module" do
    assert Tore.Harness.Artifact.Registry.lookup("RecipeProposal") == {:ok, RecipeProposal}
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/harness/artifact/recipe_proposal_test.exs`
Expected: compile error — `Tore.Harness.Artifact.RecipeProposal.__struct__/1 is undefined`.

- [ ] **Step 3: Write the artifact**

Create `lib/tore/harness/artifact/recipe_proposal.ex`:

```elixir
defmodule Tore.Harness.Artifact.RecipeProposal do
  @moduledoc """
  A recipe that does not exist in the catalog yet, awaiting user confirmation
  on a `:needs_user` card. Two sources:

    * `:web_import` — parsed from a page the user chose out of web search
      results. `source_url` carries the page.
    * `:generation` — a variant the planner generated from an existing recipe.
      `source_recipe_id` and `instruction` carry the provenance ("recipe 7,
      made simpler").

  `pending_assignment` carries the slot the user was talking about when they
  asked for the recipe ("make *tonight's* ramen vegetarian"). It rides on the
  artifact rather than the run's `input` because the slot is only known
  mid-loop, after `Commands.Open` has already written `input` — and there is
  no command for amending it. `nil` means "save the recipe, slot nothing".

  Nothing here is persisted until `Orchestrator.commit_recipe_proposal/3`
  turns it into a real `Tore.Recipes.Recipe`.
  """

  @behaviour Tore.Harness.Artifact

  @derive Jason.Encoder
  @enforce_keys [:title, :ingredients, :source]
  defstruct [
    :title,
    :description,
    :instructions,
    :base_servings,
    :prep_time_minutes,
    :cook_time_minutes,
    :source,
    :source_url,
    :source_recipe_id,
    :instruction,
    :pending_assignment,
    ingredients: [],
    tags: []
  ]

  @type ingredient :: %{
          name: String.t(),
          quantity: String.t() | nil,
          unit: String.t() | nil
        }

  @type source :: :web_import | :generation

  @type pending_assignment :: %{slot_key: String.t(), servings: pos_integer()}

  @type t :: %__MODULE__{
          title: String.t(),
          description: String.t() | nil,
          instructions: String.t() | nil,
          base_servings: pos_integer() | nil,
          prep_time_minutes: non_neg_integer() | nil,
          cook_time_minutes: non_neg_integer() | nil,
          ingredients: [ingredient()],
          tags: [String.t()],
          source: source(),
          source_url: String.t() | nil,
          source_recipe_id: integer() | nil,
          instruction: String.t() | nil,
          pending_assignment: pending_assignment() | nil
        }

  @impl true
  def kind, do: "RecipeProposal"

  @impl true
  def summary(%__MODULE__{title: title, ingredients: ingredients}) do
    %{counts: %{ingredients: length(ingredients)}, text_fallback: title}
  end

  # A generated recipe must say what it was generated from; an imported one
  # must say which page it came from. Otherwise the card cannot explain itself.
  @impl true
  def is_rationale_complete(%__MODULE__{source: :generation, instruction: i}),
    do: is_binary(i) and i != ""

  def is_rationale_complete(%__MODULE__{source: :web_import, source_url: u}),
    do: is_binary(u) and u != ""

  @impl true
  def to_json(%__MODULE__{} = proposal) do
    %{
      "title" => proposal.title,
      "description" => proposal.description,
      "instructions" => proposal.instructions,
      "base_servings" => proposal.base_servings,
      "prep_time_minutes" => proposal.prep_time_minutes,
      "cook_time_minutes" => proposal.cook_time_minutes,
      "ingredients" => Enum.map(proposal.ingredients, &ingredient_to_json/1),
      "tags" => proposal.tags,
      "source" => Atom.to_string(proposal.source),
      "source_url" => proposal.source_url,
      "source_recipe_id" => proposal.source_recipe_id,
      "instruction" => proposal.instruction,
      "pending_assignment" => pending_to_json(proposal.pending_assignment)
    }
  end

  @impl true
  def from_json(%{"title" => title} = json) do
    %__MODULE__{
      title: title,
      description: json["description"],
      instructions: json["instructions"],
      base_servings: json["base_servings"],
      prep_time_minutes: json["prep_time_minutes"],
      cook_time_minutes: json["cook_time_minutes"],
      ingredients: Enum.map(json["ingredients"] || [], &ingredient_from_json/1),
      tags: json["tags"] || [],
      source: source_from_json(json["source"]),
      source_url: json["source_url"],
      source_recipe_id: json["source_recipe_id"],
      instruction: json["instruction"],
      pending_assignment: pending_from_json(json["pending_assignment"])
    }
  end

  defp pending_to_json(nil), do: nil

  defp pending_to_json(%{slot_key: slot_key, servings: servings}),
    do: %{"slot_key" => slot_key, "servings" => servings}

  defp pending_from_json(nil), do: nil

  defp pending_from_json(%{"slot_key" => slot_key, "servings" => servings}),
    do: %{slot_key: slot_key, servings: servings}

  defp ingredient_to_json(ing) do
    %{
      "name" => ing[:name],
      "quantity" => quantity_to_string(ing[:quantity]),
      "unit" => ing[:unit]
    }
  end

  defp ingredient_from_json(json) do
    %{name: json["name"], quantity: json["quantity"], unit: json["unit"]}
  end

  defp quantity_to_string(nil), do: nil
  defp quantity_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp quantity_to_string(n) when is_number(n), do: to_string(n)
  defp quantity_to_string(s) when is_binary(s), do: s

  defp source_from_json("web_import"), do: :web_import
  defp source_from_json("generation"), do: :generation
end
```

- [ ] **Step 4: Register the kind**

In `lib/tore/harness/artifact/registry.ex`, add `RecipeProposal` to the alias list and the `@registry` map, keeping both alphabetical:

```elixir
  alias Tore.Harness.Artifact.{
    CostEntry,
    MemoryUpdate,
    PantryBeliefUpdate,
    PantrySnapshot,
    PlanDiff,
    RecipeProposal,
    RunBundle,
    RunSummary
  }

  @registry %{
    "CostEntry" => CostEntry,
    "MemoryUpdate" => MemoryUpdate,
    "PantryBeliefUpdate" => PantryBeliefUpdate,
    "PantrySnapshot" => PantrySnapshot,
    "PlanDiff" => PlanDiff,
    "RecipeProposal" => RecipeProposal,
    "RunBundle" => RunBundle,
    "RunSummary" => RunSummary
  }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/tore/harness/artifact/recipe_proposal_test.exs test/tore/harness/artifact_test.exs`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(harness): RecipeProposal artifact

SPEC §A.3 listed it; it was never built. Carries a not-yet-saved recipe
plus provenance (source URL for web imports, source recipe + instruction
for generated variants).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 2: The `RecipeProposalVerifier`

Per SPEC §A.5. Pure: no writes, no model calls. Takes the catalog titles it compares against from `ctx` so the verifier itself stays pure and testable.

**Files:**

- Create: `lib/tore/harness/verifier/recipe_proposal_verifier.ex`
- Test: `test/tore/harness/verifier/recipe_proposal_verifier_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/tore/harness/verifier/recipe_proposal_verifier_test.exs`:

```elixir
defmodule Tore.Harness.Verifier.RecipeProposalVerifierTest do
  use ExUnit.Case, async: true

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Verifier.RecipeProposalVerifier

  defp proposal(overrides \\ %{}) do
    base = %RecipeProposal{
      title: "Miso Ramen",
      instructions: "Simmer the broth. Cook the noodles.",
      base_servings: 4,
      ingredients: [
        %{name: "miso paste", quantity: "2", unit: "msk"},
        %{name: "ramen noodles", quantity: "4", unit: nil}
      ],
      source: :generation,
      source_recipe_id: 7,
      instruction: "simpler"
    }

    struct!(base, overrides)
  end

  test "a complete proposal passes" do
    assert RecipeProposalVerifier.verify(proposal(), %{}) == :ok
  end

  test "a missing title fails" do
    assert RecipeProposalVerifier.verify(proposal(%{title: ""}), %{}) ==
             {:fail, :missing_title, :reject}
  end

  test "no ingredients fails" do
    assert RecipeProposalVerifier.verify(proposal(%{ingredients: []}), %{}) ==
             {:fail, :no_ingredients, :reject}
  end

  test "an empty ingredient name fails" do
    ingredients = [%{name: "miso paste", quantity: "2", unit: "msk"}, %{name: "  ", quantity: nil, unit: nil}]

    assert RecipeProposalVerifier.verify(proposal(%{ingredients: ingredients}), %{}) ==
             {:fail, :empty_ingredient_name, :reject}
  end

  test "missing instructions fails" do
    assert RecipeProposalVerifier.verify(proposal(%{instructions: nil}), %{}) ==
             {:fail, :missing_instructions, :reject}
  end

  test "zero servings fails" do
    assert RecipeProposalVerifier.verify(proposal(%{base_servings: 0}), %{}) ==
             {:fail, :invalid_servings, :reject}
  end

  test "nil servings fails" do
    assert RecipeProposalVerifier.verify(proposal(%{base_servings: nil}), %{}) ==
             {:fail, :invalid_servings, :reject}
  end

  test "a near-duplicate of an existing catalog recipe fails" do
    existing = [
      %{
        title: "miso ramen",
        ingredient_names: ["miso paste", "ramen noodles"]
      }
    ]

    assert RecipeProposalVerifier.verify(proposal(), %{existing_recipes: existing}) ==
             {:fail, :near_duplicate, :reject}
  end

  test "a same-title recipe with different ingredients is not a duplicate" do
    existing = [%{title: "Miso Ramen", ingredient_names: ["butter", "flour", "sugar", "eggs"]}]

    assert RecipeProposalVerifier.verify(proposal(), %{existing_recipes: existing}) == :ok
  end

  test "a different-title recipe with the same ingredients is not a duplicate" do
    existing = [%{title: "Tonkotsu Ramen", ingredient_names: ["miso paste", "ramen noodles"]}]

    assert RecipeProposalVerifier.verify(proposal(), %{existing_recipes: existing}) == :ok
  end

  test "title comparison ignores case and surrounding whitespace" do
    existing = [%{title: "  MISO RAMEN ", ingredient_names: ["miso paste", "ramen noodles"]}]

    assert RecipeProposalVerifier.verify(proposal(), %{existing_recipes: existing}) ==
             {:fail, :near_duplicate, :reject}
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/harness/verifier/recipe_proposal_verifier_test.exs`
Expected: compile error — `Tore.Harness.Verifier.RecipeProposalVerifier.verify/2 is undefined`.

- [ ] **Step 3: Write the verifier**

Create `lib/tore/harness/verifier/recipe_proposal_verifier.ex`:

```elixir
defmodule Tore.Harness.Verifier.RecipeProposalVerifier do
  @moduledoc """
  Deterministic verifier for `RecipeProposal` (SPEC §A.5). Pure: no writes,
  no model calls.

  Checks:
    * title present
    * at least one ingredient, none with an empty name
    * instructions present
    * servings positive
    * not a near-duplicate of an existing catalog recipe

  Near-duplicate means *both* the same normalised title *and* a majority of
  ingredients in common — either alone is a legitimate new recipe ("Miso
  Ramen" made a different way; a second dish from the same pantry staples).

  The catalog is passed in via `ctx[:existing_recipes]` as a list of
  `%{title: String.t(), ingredient_names: [String.t()]}`, so the verifier
  itself does no IO. An absent key means "nothing to compare against".

  Repair action is `:reject` — the user edits the proposal on the
  `:needs_user` card before re-submitting.
  """

  alias Tore.Harness.Artifact.RecipeProposal

  @overlap_threshold 0.6

  @type fail_code ::
          :missing_title
          | :no_ingredients
          | :empty_ingredient_name
          | :missing_instructions
          | :invalid_servings
          | :near_duplicate
  @type repair_action :: :reject

  @spec verify(RecipeProposal.t(), map()) :: :ok | {:fail, fail_code(), repair_action()}
  def verify(%RecipeProposal{} = proposal, ctx \\ %{}) do
    with :ok <- check_title(proposal),
         :ok <- check_ingredients(proposal),
         :ok <- check_instructions(proposal),
         :ok <- check_servings(proposal) do
      check_duplicate(proposal, Map.get(ctx, :existing_recipes, []))
    end
  end

  defp check_title(%RecipeProposal{title: t}) when is_binary(t) do
    if String.trim(t) == "", do: {:fail, :missing_title, :reject}, else: :ok
  end

  defp check_title(_), do: {:fail, :missing_title, :reject}

  defp check_ingredients(%RecipeProposal{ingredients: []}), do: {:fail, :no_ingredients, :reject}

  defp check_ingredients(%RecipeProposal{ingredients: ingredients}) do
    if Enum.any?(ingredients, &blank_name?/1) do
      {:fail, :empty_ingredient_name, :reject}
    else
      :ok
    end
  end

  defp check_ingredients(_), do: {:fail, :no_ingredients, :reject}

  defp blank_name?(ing) do
    name = ing[:name] || ing["name"]
    not is_binary(name) or String.trim(name) == ""
  end

  defp check_instructions(%RecipeProposal{instructions: i}) when is_binary(i) do
    if String.trim(i) == "", do: {:fail, :missing_instructions, :reject}, else: :ok
  end

  defp check_instructions(_), do: {:fail, :missing_instructions, :reject}

  defp check_servings(%RecipeProposal{base_servings: s}) when is_integer(s) and s > 0, do: :ok
  defp check_servings(_), do: {:fail, :invalid_servings, :reject}

  defp check_duplicate(_proposal, []), do: :ok

  defp check_duplicate(%RecipeProposal{} = proposal, existing) do
    title = normalise(proposal.title)
    names = ingredient_name_set(proposal.ingredients)

    duplicate? =
      Enum.any?(existing, fn candidate ->
        normalise(candidate_title(candidate)) == title and
          overlap(names, MapSet.new(candidate_names(candidate), &normalise/1)) >=
            @overlap_threshold
      end)

    if duplicate?, do: {:fail, :near_duplicate, :reject}, else: :ok
  end

  defp candidate_title(%{title: t}), do: t
  defp candidate_title(%{"title" => t}), do: t

  defp candidate_names(%{ingredient_names: n}), do: n
  defp candidate_names(%{"ingredient_names" => n}), do: n

  defp ingredient_name_set(ingredients) do
    ingredients
    |> Enum.map(fn ing -> normalise(ing[:name] || ing["name"]) end)
    |> MapSet.new()
  end

  # Fraction of the proposal's ingredients that the candidate also has.
  defp overlap(proposed, existing) do
    if MapSet.size(proposed) == 0 do
      0.0
    else
      MapSet.intersection(proposed, existing)
      |> MapSet.size()
      |> Kernel./(MapSet.size(proposed))
    end
  end

  defp normalise(nil), do: ""
  defp normalise(s) when is_binary(s), do: s |> String.trim() |> String.downcase()
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/tore/harness/verifier/recipe_proposal_verifier_test.exs`
Expected: all 11 tests pass.

- [ ] **Step 5: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(harness): RecipeProposalVerifier

SPEC §A.5. Pure checks on a RecipeProposal: title, ingredients,
instructions, servings, and near-duplicate detection against the catalog
passed in through ctx.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 3: Web search through the LLM facade

`OpenRouter.chat_completions/3` passes the body map straight to `Req.post(json: body)`, so web search is body-only — **no `open_router` dependency change**. Add a `web_search/3` callback to the Spec so callers go through the facade like everything else.

**Files:**

- Modify: `lib/tore/llm/spec.ex`
- Modify: `lib/tore/llm.ex`
- Modify: `lib/tore/llm/openai.ex`
- Test: `test/tore/llm/openai_web_search_test.exs`

- [ ] **Step 1: Write the failing test**

The point of this test is that the request body carries the `plugins` key. `Tore.LLM.OpenAI` builds its own OpenRouter client from app config and calls `OpenRouter.chat_completions/3`, so assert on the body by capturing it through a `Req` test stub.

Create `test/tore/llm/openai_web_search_test.exs`:

```elixir
defmodule Tore.LLM.OpenAIWebSearchTest do
  use ExUnit.Case, async: false

  alias Tore.LLM.OpenAI

  setup do
    # OpenAI builds its client from app config; make sure the keys exist.
    Application.put_env(:tore, :openrouter_api_key, "test-key")
    Application.put_env(:tore, :openrouter_site_url, "http://localhost")
    Application.put_env(:tore, :openrouter_app_name, "tore-test")
    :ok
  end

  defp stub_response(test_pid, content) do
    Req.Test.stub(OpenRouter.Client, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "cost" => 0.001}
      })
    end)
  end

  test "web_search/3 puts the web plugin in the request body" do
    stub_response(self(), %{"candidates" => []})

    OpenAI.web_search("find recipes", "ramen", [])

    assert_received {:request_body, body}
    assert body["plugins"] == [%{"id" => "web", "max_results" => 5}]
  end

  test "web_search/3 honours a :max_results option" do
    stub_response(self(), %{"candidates" => []})

    OpenAI.web_search("find recipes", "ramen", max_results: 3)

    assert_received {:request_body, body}
    assert body["plugins"] == [%{"id" => "web", "max_results" => 3}]
  end

  test "web_search/3 decodes the JSON payload and usage" do
    stub_response(self(), %{
      "candidates" => [%{"title" => "Best Ramen", "url" => "https://example.com/ramen"}]
    })

    assert {:ok, %{"candidates" => [candidate]}, usage} =
             OpenAI.web_search("find recipes", "ramen", [])

    assert candidate["url"] == "https://example.com/ramen"
    assert usage.prompt_tokens == 10
  end

  test "the facade delegates web_search/3 to the configured spec" do
    # config/test.exs wires :llm_spec to Tore.MockLLM.
    Mox.expect(Tore.MockLLM, :web_search, fn "sys", "user", opts ->
      assert opts == []
      {:ok, %{"candidates" => []}, %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0.0}}
    end)

    assert {:ok, %{"candidates" => []}, _usage} = Tore.LLM.web_search("sys", "user", [])
    Mox.verify!(Tore.MockLLM)
  end
end
```

If `Req.Test.stub/2` does not intercept the `OpenRouter.Client` requests (the plug name depends on how `open_router` builds its `Req` struct), fall back to asserting the body shape through a small extracted private function instead: extract `defp web_search_body(system, user, opts)` in `Tore.LLM.OpenAI`, make it public as `@doc false def web_search_body/3`, and assert on its return value directly. Keep the facade-delegation test either way.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/llm/openai_web_search_test.exs`
Expected: FAIL — `function Tore.LLM.OpenAI.web_search/3 is undefined`.

- [ ] **Step 3: Add the callback to the Spec**

In `lib/tore/llm/spec.ex`, after the `text/3` callback, add:

```elixir
  @doc """
  A `text/3` call with the provider's web-search plugin attached. OpenRouter
  routes this to a search provider and feeds the results into the model's
  context before it answers.
  """
  @callback web_search(system :: String.t(), user :: String.t(), opts()) ::
              {:ok, map(), usage()} | {:error, term()}
```

- [ ] **Step 4: Add the facade delegate**

In `lib/tore/llm.ex`, next to `def text/3`:

```elixir
  def web_search(system, user, opts \\ []), do: spec().web_search(system, user, opts)
```

- [ ] **Step 5: Implement it in the OpenAI spec**

In `lib/tore/llm/openai.ex`, directly after `text/3`, add:

```elixir
  @impl true
  def web_search(system, user, opts) do
    system
    |> web_search_body(user, opts)
    |> chat_completions(opts)
    |> decode_json()
  end

  # OpenRouter treats web search as a body-level plugin, so no client change
  # is needed — this is `text/3`'s body plus one key.
  @doc false
  def web_search_body(system, user, opts) do
    %{
      model: Keyword.get(opts, :model, model()),
      response_format: Keyword.get(opts, :response_format, %{type: "json_object"}),
      stream: false,
      plugins: [%{id: "web", max_results: Keyword.get(opts, :max_results, 5)}],
      messages: [
        %{role: "system", content: system},
        %{role: "user", content: user}
      ]
    }
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/tore/llm/openai_web_search_test.exs`
Expected: all pass.

- [ ] **Step 7: Add the SpendGuard feature budget**

In `lib/tore/spend_guard.ex`, extend `@feature_defaults`:

```elixir
  @feature_defaults %{
    suggest_recipe: {6_000, 3},
    ambient_scan: {8_000, 600},
    recipe_web_search: {10_000, 30}
  }
```

Web search pulls page content into the prompt, so budget more tokens than a plain call; a 30-second cooldown stops a user hammering the command bar without making a genuine second search feel blocked.

- [ ] **Step 8: Run the guard tests**

Run: `mix test test/tore/spend_guard_test.exs`
Expected: pass (if the file does not exist, skip — nothing to regress).

- [ ] **Step 9: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(llm): web_search/3 through the facade

OpenRouter takes web search as a body-level plugin, so this is text/3's
body plus one key — no open_router dependency change. Gated by a new
:recipe_web_search SpendGuard budget.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 4: The two new prompt ops

Pattern A: prompts live in `Tore.LLM.Prompts` and return `{system, user}`. English prompts; locale threaded as a parameter through the existing `translation_instruction/1`.

**Files:**

- Modify: `lib/tore/llm/prompts.ex`
- Test: `test/tore/llm/prompts_recipe_intelligence_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/tore/llm/prompts_recipe_intelligence_test.exs`:

```elixir
defmodule Tore.LLM.PromptsRecipeIntelligenceTest do
  use ExUnit.Case, async: true

  alias Tore.LLM.Prompts

  describe "find_recipe_web/2" do
    test "returns a {system, user} pair carrying the query" do
      {system, user} = Prompts.find_recipe_web("weeknight ramen", nil)

      assert is_binary(system)
      assert user =~ "weeknight ramen"
    end

    test "instructs the model to return urls, not recipe bodies" do
      {system, _user} = Prompts.find_recipe_web("ramen", nil)

      assert system =~ "url"
      refute system =~ "invent"
    end

    test "the prompt is English even for a Swedish household" do
      {system, _user} = Prompts.find_recipe_web("ramen", "sv")

      assert system =~ "recipe"
      assert system =~ "Swedish"
    end

    test "web_candidates_json_schema/0 names the candidates array" do
      schema = Prompts.web_candidates_json_schema()

      assert schema.json_schema.name == "web_candidates"
      assert get_in(schema.json_schema.schema, [:properties, :candidates])
    end
  end

  describe "generate_recipe_variant/3" do
    @source %{
      title: "Miso Ramen",
      base_servings: 4,
      instructions: "Simmer the broth. Cook the noodles.",
      ingredients: [%{name: "miso paste", quantity: "2", unit: "msk"}]
    }

    test "returns a {system, user} pair carrying source recipe and instruction" do
      {system, user} = Prompts.generate_recipe_variant(@source, "make it vegetarian", nil)

      assert is_binary(system)
      assert user =~ "Miso Ramen"
      assert user =~ "make it vegetarian"
    end

    test "the system prompt carries the shared recipe schema rules" do
      {system, _user} = Prompts.generate_recipe_variant(@source, "simpler", nil)

      assert system =~ "MISE EN PLACE"
      assert system =~ "title is required"
    end

    test "locale is a parameter, not baked into the prompt" do
      {system_none, _} = Prompts.generate_recipe_variant(@source, "simpler", nil)
      {system_sv, _} = Prompts.generate_recipe_variant(@source, "simpler", "sv")

      refute system_none =~ "Swedish"
      assert system_sv =~ "Swedish"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/llm/prompts_recipe_intelligence_test.exs`
Expected: FAIL — `function Tore.LLM.Prompts.find_recipe_web/2 is undefined`.

- [ ] **Step 3: Add the ops**

In `lib/tore/llm/prompts.ex`, after `normalise_recipe/2` (which ends around line 197), add:

```elixir
  @web_candidates_schema %{
    type: "object",
    properties: %{
      candidates: %{
        type: "array",
        items: %{
          type: "object",
          properties: %{
            title: %{type: "string"},
            url: %{type: "string"}
          },
          required: ["title", "url"],
          additionalProperties: false
        }
      }
    },
    required: ["candidates"],
    additionalProperties: false
  }

  def web_candidates_json_schema do
    %{
      type: "json_schema",
      json_schema: %{name: "web_candidates", strict: true, schema: @web_candidates_schema}
    }
  end

  @doc """
  Discovery only. The model searches the web and hands back candidate recipe
  pages; it never writes the recipe itself — the chosen URL goes through the
  existing scraper, so the recipe text always comes from the real page.
  """
  def find_recipe_web(query, locale \\ nil) do
    system = """
    You find recipe pages on the web. Search for pages matching the user's request.

    Return a JSON object: {"candidates": [{"title": "...", "url": "..."}]}
    Rules:
    - return at most 5 candidates, best match first
    - each url must be a direct link to a single recipe page you actually found in the search results
    - never return a search-results page, a category listing, or a homepage
    - the title is the recipe's name as the page states it
    - prefer pages that show ingredients and steps as text
    - if nothing suitable was found, return {"candidates": []}
    - do not write out any recipe content — only titles and urls
    #{locale_preference_instruction(locale)}
    Respond with a JSON object only. No prose.
    """

    {system, query}
  end

  @doc """
  Generate a variant of an existing recipe (simpler, vegetarian, scaled to a
  different number of servings, …). The result is a complete recipe in the
  Tore schema, surfaced as a proposal — never auto-committed.
  """
  def generate_recipe_variant(source_recipe, instruction, locale \\ nil) do
    system = """
    You adapt an existing recipe. The user gives you a source recipe and an
    instruction describing how to change it. Produce the complete adapted recipe.

    Return a JSON object matching this exact structure:
    #{@recipe_schema}
    Rules:
    #{@recipe_rules}
    - the adapted recipe must stand alone: full ingredients and full steps, not a diff against the source
    - give it a title that says how it differs from the source
    - keep every change traceable to the instruction — change nothing the user did not ask for
    - when the instruction changes servings, scale every quantity accordingly and set base_servings to the requested number
    #{translation_instruction(locale)}
    """

    user =
      Jason.encode!(%{
        source_recipe: source_recipe,
        instruction: instruction
      })

    {system, user}
  end

  # Search results are better in the household's own language, but the prompt
  # itself stays English — locale is a parameter, never baked in.
  defp locale_preference_instruction(nil), do: ""

  defp locale_preference_instruction(locale) do
    case Map.get(@locale_names, locale) do
      nil -> ""
      language -> "- prefer recipe pages written in #{language}, but return good pages in any language if there are none"
    end
  end
```

Note: `@recipe_schema`, `@recipe_rules`, `@locale_names`, and `translation_instruction/1` already exist in this module. `locale_preference_instruction/1` must be defined **after** the `@locale_names` module attribute (which sits at ~line 220) — put the two public functions where described and the private helper next to `translation_instruction/1` at the bottom of that section.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/tore/llm/prompts_recipe_intelligence_test.exs`
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(llm): find_recipe_web and generate_recipe_variant prompt ops

Discovery prompt returns titles+urls only (the scraper produces the recipe
body). Variant prompt reuses the shared recipe schema and rules. Both are
English with locale threaded as a parameter.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 5: `Tore.Recipes.Variant` — build a proposal from a source recipe

This module owns the generation LLM call and the mapping from raw model JSON to a `RecipeProposal`. Keeping it out of `PlannerTools` means it can be tested without the tool loop.

**Files:**

- Create: `lib/tore/recipes/variant.ex`
- Test: `test/tore/recipes/variant_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/tore/recipes/variant_test.exs`:

```elixir
defmodule Tore.Recipes.VariantTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Recipes.Variant

  defp source_recipe do
    {:ok, recipe} =
      Tore.Recipes.create(%{
        title: "Miso Ramen",
        instructions: "Simmer the broth. Cook the noodles.",
        base_servings: 4,
        ingredients: [
          %{name: "miso paste", quantity: Decimal.new("2"), unit: "msk"},
          %{name: "pork belly", quantity: Decimal.new("300"), unit: "g"}
        ]
      })

    recipe
  end

  defp model_payload do
    %{
      "title" => "Vegetarian Miso Ramen",
      "description" => "Miso ramen without the pork.",
      "base_servings" => 4,
      "prep_time_minutes" => 10,
      "cook_time_minutes" => 20,
      "ingredients" => [
        %{"item" => "miso paste", "quantity" => 2, "unit" => "msk"},
        %{"item" => "firm tofu", "quantity" => 300, "unit" => "g"}
      ],
      "steps" => [
        %{"order" => 1, "phase" => "MISE EN PLACE", "action" => "Cube the tofu.", "ingredients" => ["firm tofu"]},
        %{"order" => 2, "phase" => "COOKING", "action" => "Simmer the broth.", "ingredients" => ["miso paste"]}
      ],
      "tags" => ["japanese", "vegetarian"]
    }
  end

  test "build/2 returns a RecipeProposal carrying provenance" do
    recipe = source_recipe()

    expect(Tore.MockLLM, :text, fn _system, _user, _opts ->
      {:ok, model_payload(), %{prompt_tokens: 100, completion_tokens: 200, cost_usd: 0.002}}
    end)

    assert {:ok, %RecipeProposal{} = proposal, usage} =
             Variant.build(recipe, "make it vegetarian")

    assert proposal.title == "Vegetarian Miso Ramen"
    assert proposal.source == :generation
    assert proposal.source_recipe_id == recipe.id
    assert proposal.instruction == "make it vegetarian"
    assert proposal.base_servings == 4
    assert usage.completion_tokens == 200
  end

  test "build/2 maps model ingredients into proposal ingredients" do
    recipe = source_recipe()

    expect(Tore.MockLLM, :text, fn _, _, _ ->
      {:ok, model_payload(), %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    {:ok, proposal, _usage} = Variant.build(recipe, "make it vegetarian")

    assert proposal.ingredients == [
             %{name: "miso paste", quantity: "2", unit: "msk"},
             %{name: "firm tofu", quantity: "300", unit: "g"}
           ]
  end

  test "build/2 flattens the steps into instructions text" do
    recipe = source_recipe()

    expect(Tore.MockLLM, :text, fn _, _, _ ->
      {:ok, model_payload(), %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    {:ok, proposal, _usage} = Variant.build(recipe, "make it vegetarian")

    assert proposal.instructions =~ "Cube the tofu."
    assert proposal.instructions =~ "Simmer the broth."
  end

  test "build/2 sends the source recipe's ingredients to the model" do
    recipe = source_recipe()
    test_pid = self()

    expect(Tore.MockLLM, :text, fn _system, user, _opts ->
      send(test_pid, {:user_prompt, user})
      {:ok, model_payload(), %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    {:ok, _proposal, _usage} = Variant.build(recipe, "make it vegetarian")

    assert_received {:user_prompt, user}
    assert user =~ "Miso Ramen"
    assert user =~ "pork belly"
  end

  test "build/2 propagates an LLM error" do
    recipe = source_recipe()

    expect(Tore.MockLLM, :text, fn _, _, _ -> {:error, :timeout} end)

    assert {:error, :timeout} = Variant.build(recipe, "make it vegetarian")
  end

  test "build/2 rejects a payload with no title" do
    recipe = source_recipe()

    expect(Tore.MockLLM, :text, fn _, _, _ ->
      {:ok, %{"ingredients" => []}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    assert {:error, :invalid_response} = Variant.build(recipe, "make it vegetarian")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/recipes/variant_test.exs`
Expected: FAIL — `Tore.Recipes.Variant.build/2 is undefined`.

- [ ] **Step 3: Write the module**

Create `lib/tore/recipes/variant.ex`:

```elixir
defmodule Tore.Recipes.Variant do
  @moduledoc """
  Generate a variant of an existing recipe ("simpler", "vegetarian", "for 6")
  as a `RecipeProposal`. Nothing is written to the catalog here — the
  proposal goes to a `:needs_user` card and only
  `Orchestrator.commit_recipe_proposal/3` turns it into a real recipe
  (SPEC §A.6.1: invented content never auto-commits).
  """

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.LLM
  alias Tore.LLM.Prompts

  @spec build(Tore.Recipes.Recipe.t(), String.t(), String.t() | nil) ::
          {:ok, RecipeProposal.t(), LLM.usage()} | {:error, term()}
  def build(source_recipe, instruction, locale \\ nil) do
    locale = locale || household_locale()
    {system, user} = Prompts.generate_recipe_variant(summarise(source_recipe), instruction, locale)

    case LLM.text(system, user, response_format: Prompts.recipe_json_schema()) do
      {:ok, %{"title" => title} = payload, usage} when is_binary(title) and title != "" ->
        {:ok, to_proposal(payload, source_recipe, instruction), usage}

      {:ok, _payload, _usage} ->
        {:error, :invalid_response}

      {:error, _} = err ->
        err
    end
  end

  # What the model needs to see of the source: the shape of the dish, not our
  # internal ids.
  defp summarise(recipe) do
    %{
      title: recipe.title,
      description: recipe.description,
      base_servings: recipe.base_servings,
      prep_time_minutes: recipe.prep_time_minutes,
      cook_time_minutes: recipe.cook_time_minutes,
      instructions: recipe.instructions,
      ingredients: Enum.map(recipe.recipe_ingredients || [], &summarise_ingredient/1)
    }
  end

  defp summarise_ingredient(ri) do
    %{
      name: ri.ingredient && ri.ingredient.name,
      quantity: ri.quantity && Decimal.to_string(ri.quantity),
      unit: ri.unit
    }
  end

  defp to_proposal(payload, source_recipe, instruction) do
    %RecipeProposal{
      title: payload["title"],
      description: payload["description"],
      instructions: flatten_steps(payload["steps"]),
      base_servings: payload["base_servings"] || source_recipe.base_servings,
      prep_time_minutes: payload["prep_time_minutes"],
      cook_time_minutes: payload["cook_time_minutes"],
      ingredients: Enum.map(payload["ingredients"] || [], &ingredient_from_payload/1),
      tags: payload["tags"] || [],
      source: :generation,
      source_recipe_id: source_recipe.id,
      instruction: instruction
    }
  end

  defp ingredient_from_payload(item) do
    %{
      name: item["item"] || item["name"],
      quantity: quantity_to_string(item["quantity"]),
      unit: item["unit"]
    }
  end

  defp quantity_to_string(nil), do: nil
  defp quantity_to_string(n) when is_integer(n), do: Integer.to_string(n)
  defp quantity_to_string(n) when is_float(n), do: n |> Float.round(2) |> Float.to_string()
  defp quantity_to_string(s) when is_binary(s), do: s

  defp flatten_steps(nil), do: nil
  defp flatten_steps([]), do: nil

  defp flatten_steps(steps) when is_list(steps) do
    steps
    |> Enum.sort_by(& &1["order"])
    |> Enum.map_join("\n", & &1["action"])
  end

  defp household_locale do
    case Tore.Household.get_household!() do
      %{locale: locale} when is_binary(locale) -> locale
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/tore/recipes/variant_test.exs`
Expected: all 6 tests pass.

If `quantity_to_string/1` produces `"2.0"` where the test expects `"2"`, the model payload used integers — check that `is_integer(n)` clause comes before the float clause (it does above). If `Tore.Recipes.create/1` in the test fixture rejects the ingredient shape, check `insert_ingredients/2` in `lib/tore/recipes.ex:224` for the accepted keys.

- [ ] **Step 5: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(recipes): Variant.build/3 — generate a recipe variant as a proposal

Owns the generation LLM call and the model-JSON -> RecipeProposal mapping.
Writes nothing: the proposal goes to a :needs_user card.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 6: The `find_recipe_web` planner tool

A read tool. Discovery only — it returns candidate `{title, url}` pairs. The planner then imports the chosen URL through the existing scraper (Task 7 covers wiring that import into the proposal path; this task is just discovery).

**Files:**

- Modify: `lib/tore/llm/planner_tools.ex`
- Test: `test/tore/llm/planner_tools_web_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/tore/llm/planner_tools_web_test.exs`:

```elixir
defmodule Tore.LLM.PlannerToolsWebTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.LLM.PlannerTools
  alias Tore.Planning.State

  @plan %State{}
  @ctx %{plan_id: "plan-1", week_start: ~D[2026-06-01], household_id: 1}

  defp tool(name), do: Enum.find(PlannerTools.all(), &(&1.name == name))

  test "find_recipe_web is a read tool in the catalog" do
    assert %{kind: :read} = tool("find_recipe_web")
  end

  test "find_recipe_web returns candidate titles and urls" do
    expect(Tore.MockLLM, :web_search, fn _system, _user, _opts ->
      {:ok,
       %{
         "candidates" => [
           %{"title" => "Best Miso Ramen", "url" => "https://example.com/ramen"},
           %{"title" => "Quick Ramen", "url" => "https://example.com/quick"}
         ]
       }, %{prompt_tokens: 10, completion_tokens: 5, cost_usd: 0.001}}
    end)

    assert {:ok, result, [], @plan} =
             tool("find_recipe_web").run.(%{"query" => "miso ramen"}, @ctx, @plan)

    assert result.candidates == [
             %{title: "Best Miso Ramen", url: "https://example.com/ramen"},
             %{title: "Quick Ramen", url: "https://example.com/quick"}
           ]
  end

  test "find_recipe_web reports no matches without erroring" do
    expect(Tore.MockLLM, :web_search, fn _, _, _ ->
      {:ok, %{"candidates" => []}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    assert {:ok, %{candidates: [], not_found: true}, [], @plan} =
             tool("find_recipe_web").run.(%{"query" => "unobtainium stew"}, @ctx, @plan)
  end

  test "find_recipe_web returns a resting message when SpendGuard blocks it" do
    # Burn the cooldown by logging a call for the feature right now.
    Tore.Costs.log_llm_usage(%{
      feature: "recipe_web_search",
      prompt_tokens: 1,
      completion_tokens: 1,
      cost_usd: Decimal.new("0.0001")
    })

    assert {:ok, %{unavailable: true} = result, [], @plan} =
             tool("find_recipe_web").run.(%{"query" => "ramen"}, @ctx, @plan)

    assert result.reason =~ "resting"
  end

  test "find_recipe_web surfaces an LLM error as a tool error" do
    expect(Tore.MockLLM, :web_search, fn _, _, _ -> {:error, :timeout} end)

    assert {:error, :timeout} =
             tool("find_recipe_web").run.(%{"query" => "ramen"}, @ctx, @plan)
  end

  test "the tool declares a required query parameter" do
    assert tool("find_recipe_web").parameters.required == ["query"]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/llm/planner_tools_web_test.exs`
Expected: FAIL — `tool("find_recipe_web")` is `nil`, so `.run` raises `KeyError`.

- [ ] **Step 3: Add the tool**

In `lib/tore/llm/planner_tools.ex`:

Add to `all/0`, after `active_deals()`:

```elixir
      active_deals(),
      find_recipe_web()
```

Then add the tool definition after `defp active_deals do ... end`:

```elixir
  defp find_recipe_web do
    %Tool{
      name: "find_recipe_web",
      description:
        "Search the web for recipe pages when the local catalog has nothing suitable. " <>
          "Returns candidate titles and urls only — pick one and import it; never write the recipe yourself.",
      kind: :read,
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "What kind of recipe to look for, e.g. \"quick weeknight ramen\""
          }
        },
        required: ["query"]
      },
      run: fn args, _ctx, plan ->
        case SpendGuard.allow?(:recipe_web_search) do
          :ok -> search_web(args["query"], plan)
          {:error, _reason} -> {:ok, %{unavailable: true, reason: guard_message()}, [], plan}
        end
      end
    }
  end

  defp search_web(query, plan) do
    {system, user} = Prompts.find_recipe_web(query, household_locale())

    case Tore.LLM.web_search(system, user,
           response_format: Prompts.web_candidates_json_schema()
         ) do
      {:ok, payload, usage} ->
        SpendGuard.log_usage(:recipe_web_search, usage)
        {:ok, candidates_result(payload["candidates"] || []), [], plan}

      {:error, _} = err ->
        err
    end
  end

  defp candidates_result([]), do: %{candidates: [], not_found: true}

  defp candidates_result(candidates) do
    %{candidates: Enum.map(candidates, &%{title: &1["title"], url: &1["url"]})}
  end

  defp guard_message,
    do: "web search is resting — try again shortly"

  defp household_locale do
    case Tore.Household.get_household!() do
      %{locale: locale} when is_binary(locale) -> locale
      _ -> nil
    end
  end
```

Add the new aliases at the top of the module, next to the existing ones:

```elixir
  alias Tore.LLM.{Tool, Prompts}
  alias Tore.SpendGuard
```

(the existing `alias Tore.LLM.Tool` line becomes the first of these — do not leave a duplicate alias for `Tool`.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/tore/llm/planner_tools_web_test.exs test/tore/llm/planner_tools_test.exs`
Expected: all pass. If the existing `planner_tools_test.exs` has an assertion on the exact tool list, update it to include `"find_recipe_web"`.

- [ ] **Step 5: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(planner): find_recipe_web read tool

Discovery only (D2): returns candidate titles and urls; the chosen url goes
through the existing scraper. SpendGuard-gated under :recipe_web_search.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 7: The loop-terminating proposal signal

`generate_recipe_variant` and `import_recipe_from_web` both end the planner loop with a proposal instead of a plan mutation. Teach `PlannerAgent` the signal first, then add the tools that emit it.

**Files:**

- Modify: `lib/tore/llm/planner_agent.ex`
- Test: `test/tore/llm/planner_agent_test.exs` (append)

- [ ] **Step 1: Write the failing test**

Append to `test/tore/llm/planner_agent_test.exs` (inside the top-level `describe`-less body, at the end of the module before the final `end`):

```elixir
  test "run/4 stops the loop when a read tool returns {:proposal, ...}" do
    proposal = %Tore.Harness.Artifact.RecipeProposal{
      title: "Simpler Ramen",
      ingredients: [%{name: "miso paste", quantity: "2", unit: "msk"}],
      instructions: "Simmer. Serve.",
      base_servings: 4,
      source: :generation,
      source_recipe_id: 1,
      instruction: "simpler"
    }

    proposal_tool = %Tore.LLM.Tool{
      name: "fake_proposal_tool",
      description: "test double",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _args, _ctx, plan ->
        {:proposal, proposal, %{slot_key: "mon_dinner", servings: 4}, plan}
      end
    }

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "fake_proposal_tool", args: %{}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    ctx = Map.put(@ctx, :extra_tools, [proposal_tool])

    assert {:ok, outcome} = PlannerAgent.run(@system_prompt, "make it simpler", ctx, [])

    assert {:proposal, ^proposal, pending} = outcome.result
    assert pending == %{slot_key: "mon_dinner", servings: 4}
  end

  test "run/4 makes no further model round-trips after a proposal" do
    proposal = %Tore.Harness.Artifact.RecipeProposal{
      title: "Simpler Ramen",
      ingredients: [%{name: "miso paste", quantity: "2", unit: "msk"}],
      instructions: "Simmer.",
      base_servings: 4,
      source: :generation,
      source_recipe_id: 1,
      instruction: "simpler"
    }

    proposal_tool = %Tore.LLM.Tool{
      name: "fake_proposal_tool",
      description: "test double",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _args, _ctx, plan -> {:proposal, proposal, %{}, plan} end
    }

    # Exactly one call — a second would mean the loop kept going.
    expect(Tore.MockLLM, :chat_with_tools, 1, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "fake_proposal_tool", args: %{}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    ctx = Map.put(@ctx, :extra_tools, [proposal_tool])

    assert {:ok, outcome} = PlannerAgent.run(@system_prompt, "make it simpler", ctx, [])
    assert match?({:proposal, _, _}, outcome.result)
  end
```

The `:extra_tools` ctx key is a test seam: it lets the loop be tested with a double instead of driving a real LLM call inside a tool. It is small, and the alternative (stubbing `Tore.MockLLM` twice with different expectations inside one loop) is much harder to read.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/llm/planner_agent_test.exs`
Expected: FAIL — the new tests fail; `fake_proposal_tool` is not in the catalog so the loop records `unknown_tool` and keeps going.

- [ ] **Step 3: Extend the type and the tool catalog**

In `lib/tore/llm/planner_agent.ex`, extend the `result` type:

```elixir
  @type result ::
          {:message, String.t()}
          | {:question, String.t()}
          | {:capped, String.t()}
          | {:proposal, struct(), map()}
```

In `run/4`, allow ctx-supplied tools:

```elixir
    tools = PlannerTools.all() ++ Map.get(ctx, :extra_tools, [])
```

- [ ] **Step 4: Handle the signal in the loop**

In `run_and_record/4`, add a clause for the proposal return before the existing `{:ok, result, events, next_plan}` clause:

```elixir
  defp run_and_record(tool, call, rest, state) do
    case Tool.validate_args(tool, call.args) do
      :ok ->
        case tool.run.(call.args, state.ctx, state.working_plan) do
          # A proposal ends the loop: the run parks in :needs_user for the
          # user to confirm, so there is nothing more for the model to do.
          {:proposal, proposal, pending, next_plan} ->
            state = %{state | working_plan: next_plan}

            state =
              append_tool_result(state, call, %{
                ok: true,
                proposal: proposal.title,
                awaiting_user: true
              })

            state =
              Enum.reduce(rest, state, fn pending_call, acc ->
                append_tool_result(acc, pending_call, %{error: "superseded_by_proposal"})
              end)

            {:terminal_proposal, proposal, pending, state}

          {:ok, result, events, next_plan} ->
            {handles, result} = Map.pop(result, :__handles__)

            state = %{
              state
              | working_plan: next_plan,
                plan_events: state.plan_events ++ events,
                handles: register_handles(state.handles, handles)
            }

            execute_calls(rest, append_tool_result(state, call, result))

          {:error, reason} ->
            execute_calls(rest, append_tool_result(state, call, %{error: inspect(reason)}))
        end

      {:error, reason} ->
        execute_calls(rest, append_tool_result(state, call, %{error: inspect(reason)}))
    end
  end
```

`run_and_record/4` is called from both `handle_tool/4` clauses, and its return value flows up through `execute_calls/2` to `loop/2`. Add the matching branch in `loop/2`'s `case execute_calls(calls, state) do`:

```elixir
        case execute_calls(calls, state) do
          {:terminal_question, q, state} ->
            finish(state, {:question, q})

          {:terminal_proposal, proposal, pending, state} ->
            finish(state, {:proposal, proposal, pending})

          {:cap_hit, state} ->
            loop(system, %{state | round_trips: state.max_round_trips})

          {:continue, state} ->
            loop(system, state)
        end
```

`execute_calls/2` passes any non-`{:continue, _}` tuple straight up because the recursive call is in the tail position of the `{:continue, …}` path only — verify by reading `execute_calls/2`; if it pattern-matches narrowly, widen it to pass `{:terminal_proposal, _, _, _}` through unchanged the same way `{:terminal_question, _, _}` already is.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/tore/llm/planner_agent_test.exs`
Expected: all pass, including the pre-existing tests.

- [ ] **Step 6: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(planner): loop-terminating {:proposal, ...} signal

A read tool can now end the loop with a proposal instead of a plan
mutation. The orchestrator turns that into :needs_user (D5).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 8: The `generate_recipe_variant` and `import_recipe_from_web` tools

Two read tools that emit the signal from Task 7. `generate_recipe_variant` uses `Tore.Recipes.Variant`; `import_recipe_from_web` scrapes a URL the planner chose out of `find_recipe_web` results and turns it into a `RecipeProposal` — this is the missing half of the web-find flow.

**Files:**

- Modify: `lib/tore/llm/planner_tools.ex`
- Test: `test/tore/llm/planner_tools_proposal_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/tore/llm/planner_tools_proposal_test.exs`:

```elixir
defmodule Tore.LLM.PlannerToolsProposalTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Handles
  alias Tore.LLM.PlannerTools
  alias Tore.Planning.State

  @plan %State{}

  defp tool(name), do: Enum.find(PlannerTools.all(), &(&1.name == name))

  defp source_recipe do
    {:ok, recipe} =
      Tore.Recipes.create(%{
        title: "Miso Ramen",
        instructions: "Simmer the broth.",
        base_servings: 4,
        ingredients: [%{name: "pork belly", quantity: Decimal.new("300"), unit: "g"}]
      })

    recipe
  end

  defp variant_payload do
    %{
      "title" => "Vegetarian Miso Ramen",
      "base_servings" => 4,
      "ingredients" => [%{"item" => "firm tofu", "quantity" => 300, "unit" => "g"}],
      "steps" => [%{"order" => 1, "phase" => "COOKING", "action" => "Simmer.", "ingredients" => []}],
      "tags" => ["vegetarian"]
    }
  end

  describe "generate_recipe_variant" do
    test "is a read tool" do
      assert %{kind: :read} = tool("generate_recipe_variant")
    end

    test "returns a loop-terminating proposal carrying provenance" do
      recipe = source_recipe()
      handle = Handles.recipe(recipe.id, recipe.title, :direct_touch, 1.0)
      ctx = %{household_id: 1, handles: %{handle.ref => handle}}

      expect(Tore.MockLLM, :text, fn _, _, _ ->
        {:ok, variant_payload(), %{prompt_tokens: 10, completion_tokens: 20, cost_usd: 0.001}}
      end)

      args = %{"recipe_ref" => handle.ref, "instruction" => "make it vegetarian"}

      assert {:proposal, %RecipeProposal{} = proposal, pending, @plan} =
               tool("generate_recipe_variant").run.(args, ctx, @plan)

      assert proposal.title == "Vegetarian Miso Ramen"
      assert proposal.source == :generation
      assert proposal.source_recipe_id == recipe.id
      assert pending == %{}
    end

    test "carries a pending slot assignment when slot_key is given" do
      recipe = source_recipe()
      handle = Handles.recipe(recipe.id, recipe.title, :direct_touch, 1.0)
      ctx = %{household_id: 1, handles: %{handle.ref => handle}}

      expect(Tore.MockLLM, :text, fn _, _, _ ->
        {:ok, variant_payload(), %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
      end)

      args = %{
        "recipe_ref" => handle.ref,
        "instruction" => "for 6",
        "slot_key" => "mon_dinner",
        "servings" => 6
      }

      assert {:proposal, _proposal, pending, @plan} =
               tool("generate_recipe_variant").run.(args, ctx, @plan)

      assert pending == %{slot_key: "mon_dinner", servings: 6}
    end

    test "rejects an unknown recipe_ref" do
      ctx = %{household_id: 1, handles: %{}}
      args = %{"recipe_ref" => "rcp_nope", "instruction" => "simpler"}

      assert {:error, message} = tool("generate_recipe_variant").run.(args, ctx, @plan)
      assert message =~ "unknown recipe_ref"
    end

    test "propagates a generation failure" do
      recipe = source_recipe()
      handle = Handles.recipe(recipe.id, recipe.title, :direct_touch, 1.0)
      ctx = %{household_id: 1, handles: %{handle.ref => handle}}

      expect(Tore.MockLLM, :text, fn _, _, _ -> {:error, :timeout} end)

      args = %{"recipe_ref" => handle.ref, "instruction" => "simpler"}
      assert {:error, :timeout} = tool("generate_recipe_variant").run.(args, ctx, @plan)
    end
  end

  describe "import_recipe_from_web" do
    test "is a read tool" do
      assert %{kind: :read} = tool("import_recipe_from_web")
    end

    test "scrapes the chosen url into a web_import proposal" do
      html = """
      <html><head><script type="application/ld+json">
      {"@type":"Recipe","name":"Best Miso Ramen","recipeIngredient":["2 msk miso paste"],
       "recipeInstructions":[{"@type":"HowToStep","text":"Simmer the broth."}],
       "recipeYield":"4"}
      </script></head><body></body></html>
      """

      expect(Tore.MockHTTP, :fetch, fn "https://example.com/ramen" -> {:ok, html} end)

      args = %{"url" => "https://example.com/ramen"}

      assert {:proposal, %RecipeProposal{} = proposal, %{}, @plan} =
               tool("import_recipe_from_web").run.(args, %{household_id: 1}, @plan)

      assert proposal.source == :web_import
      assert proposal.source_url == "https://example.com/ramen"
      assert proposal.title =~ "Ramen"
      assert proposal.ingredients != []
    end

    test "surfaces a scrape failure as a tool error" do
      expect(Tore.MockHTTP, :fetch, fn _url -> {:error, :timeout} end)

      args = %{"url" => "https://example.com/down"}

      assert {:error, :timeout} =
               tool("import_recipe_from_web").run.(args, %{household_id: 1}, @plan)
    end
  end
end
```

If the JSON-LD fixture does not exercise the scraper's parse path (check `parse_or_extract/2` in `lib/tore/recipes.ex`), stub `Tore.MockLLM.text/3` for the HTML-extraction fallback in the same test instead, returning the `variant_payload()` shape.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/llm/planner_tools_proposal_test.exs`
Expected: FAIL — both tools are `nil`.

- [ ] **Step 3: Add a proposal-building path that does not persist**

`Tore.Recipes.scrape_from_url/2` fetches, parses, **and creates** — but a proposal must not write to the catalog until the user confirms. Add a non-persisting sibling in `lib/tore/recipes.ex`, right after `scrape_from_url/2`:

```elixir
  @doc """
  Fetch and parse a recipe URL **without** writing it to the catalog. Used by
  the planner's proposal path, where the user confirms before anything is
  saved. `scrape_from_url/2` is the eager version.
  """
  @spec scrape_attrs_from_url(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def scrape_attrs_from_url(url, locale \\ nil) do
    locale = locale || household_locale()

    with {:ok, html} <- @http.fetch(url),
         {:ok, attrs} <- parse_or_extract(html, locale) do
      {:ok, Map.put(attrs, :source_url, url)}
    end
  end
```

Then refactor `scrape_and_create/2` to use it, so there is one fetch-and-parse path:

```elixir
  @spec scrape_and_create(String.t(), String.t() | nil) ::
          {:ok, Recipe.t()} | {:error, term()}
  def scrape_and_create(url, locale \\ nil) do
    with {:ok, attrs} <- scrape_attrs_from_url(url, locale) do
      create(attrs)
    end
  end
```

- [ ] **Step 4: Add the two tools**

In `lib/tore/llm/planner_tools.ex`, add both to `all/0`:

```elixir
      active_deals(),
      find_recipe_web(),
      import_recipe_from_web(),
      generate_recipe_variant()
```

Then add the definitions after `find_recipe_web/0`:

```elixir
  defp import_recipe_from_web do
    %Tool{
      name: "import_recipe_from_web",
      description:
        "Import a recipe from a url returned by find_recipe_web. Produces a proposal the user " <>
          "confirms before it enters the catalog. This ends your turn — do not call anything after it.",
      kind: :read,
      parameters: %{
        type: "object",
        properties: %{
          url: %{type: "string", description: "a url from find_recipe_web's candidates"},
          slot_key: %{
            type: "string",
            description: "optional — the slot to assign the recipe to once the user confirms"
          },
          servings: %{type: "integer", minimum: 1}
        },
        required: ["url"]
      },
      run: fn args, _ctx, plan ->
        case Tore.Recipes.scrape_attrs_from_url(args["url"], household_locale()) do
          {:ok, attrs} ->
            proposal = web_import_proposal(attrs, args["url"])
            {:proposal, proposal, pending_assignment(args), plan}

          {:error, _} = err ->
            err
        end
      end
    }
  end

  defp generate_recipe_variant do
    %Tool{
      name: "generate_recipe_variant",
      description:
        "Create a variant of an existing recipe — simpler, vegetarian, scaled to different " <>
          "servings, and so on. Produces a proposal the user confirms before it enters the " <>
          "catalog. This ends your turn — do not call anything after it.",
      kind: :read,
      parameters: %{
        type: "object",
        properties: %{
          recipe_ref: %{
            type: "string",
            description: "a ref returned by search_recipes, resolve_recipe, or resolve_slot"
          },
          instruction: %{
            type: "string",
            description: "how to change it, e.g. \"make it vegetarian\", \"simpler\", \"for 6\""
          },
          slot_key: %{
            type: "string",
            description: "optional — the slot to assign the variant to once the user confirms"
          },
          servings: %{type: "integer", minimum: 1}
        },
        required: ["recipe_ref", "instruction"]
      },
      run: fn args, ctx, plan ->
        # Read tools do not get the agent's recipe_ref exchange (that runs for
        # action tools only), so resolve the handle here.
        with {:ok, recipe_id} <- fetch_recipe_id(ctx, args["recipe_ref"]),
             recipe = Tore.Recipes.get!(recipe_id),
             {:ok, proposal, usage} <-
               Tore.Recipes.Variant.build(recipe, args["instruction"], household_locale()) do
          SpendGuard.log_usage(:recipe_variant, usage)
          {:proposal, proposal, pending_assignment(args), plan}
        end
      end
    }
  end

  defp fetch_recipe_id(ctx, ref) do
    case Handles.fetch(Map.get(ctx, :handles, %{}), ref) do
      {:ok, %Handles.ResolvedRecipe{id: id}} ->
        {:ok, id}

      _ ->
        {:error,
         "unknown recipe_ref #{inspect(ref)} — call search_recipes or resolve_recipe first and use a ref from the result"}
    end
  end

  defp pending_assignment(%{"slot_key" => slot_key} = args) when is_binary(slot_key) do
    %{slot_key: slot_key, servings: args["servings"] || 4}
  end

  defp pending_assignment(_args), do: %{}

  defp web_import_proposal(attrs, url) do
    %Tore.Harness.Artifact.RecipeProposal{
      title: attrs[:title],
      description: attrs[:description],
      instructions: attrs[:instructions],
      base_servings: attrs[:base_servings],
      prep_time_minutes: attrs[:prep_time_minutes],
      cook_time_minutes: attrs[:cook_time_minutes],
      ingredients: Enum.map(attrs[:ingredients] || [], &web_import_ingredient/1),
      tags: attrs[:tags] || [],
      source: :web_import,
      source_url: url
    }
  end

  defp web_import_ingredient(ing) do
    %{
      name: ing[:name] || ing["name"],
      quantity: quantity_to_string(ing[:quantity] || ing["quantity"]),
      unit: ing[:unit] || ing["unit"]
    }
  end

  defp quantity_to_string(nil), do: nil
  defp quantity_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp quantity_to_string(n) when is_number(n), do: to_string(n)
  defp quantity_to_string(s) when is_binary(s), do: s
```

Add a `:recipe_variant` budget in `lib/tore/spend_guard.ex` alongside the one from Task 3 — generation is a strong-model call, so it gets its own line:

```elixir
  @feature_defaults %{
    suggest_recipe: {6_000, 3},
    ambient_scan: {8_000, 600},
    recipe_web_search: {10_000, 30},
    recipe_variant: {12_000, 10}
  }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/tore/llm/planner_tools_proposal_test.exs test/tore/llm/planner_tools_test.exs test/tore/recipes_test.exs`
Expected: all pass. The `recipes_test.exs` run guards the `scrape_and_create/2` refactor.

- [ ] **Step 6: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(planner): generate_recipe_variant and import_recipe_from_web tools

Both are read tools returning the loop-terminating proposal signal.
Recipes.scrape_attrs_from_url/2 splits fetch-and-parse from create so the
proposal path writes nothing until the user confirms.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 9: The orchestrator's `:needs_user` branch

`close/4` currently handles `{:message, _}`, `{:capped, _}`, and `{:question, _}`. Add the `{:proposal, _, _}` branch: verify, attach the artifact, and raise a question so the run parks in `:needs_user`.

**Files:**

- Modify: `lib/tore/harness/orchestrator.ex`
- Test: `test/tore/harness/recipe_proposal_run_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/tore/harness/recipe_proposal_run_test.exs`:

```elixir
defmodule Tore.Harness.RecipeProposalRunTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run.State

  setup do
    household = Tore.Household.get_household!()
    plan_stream_id = "plan:" <> Ecto.UUID.generate()
    {:ok, household: household, plan_stream_id: plan_stream_id}
  end

  defp source_recipe do
    {:ok, recipe} =
      Tore.Recipes.create(%{
        title: "Miso Ramen",
        instructions: "Simmer the broth.",
        base_servings: 4,
        ingredients: [%{name: "pork belly", quantity: Decimal.new("300"), unit: "g"}]
      })

    recipe
  end

  defp variant_payload do
    %{
      "title" => "Vegetarian Miso Ramen",
      "base_servings" => 4,
      "ingredients" => [%{"item" => "firm tofu", "quantity" => 300, "unit" => "g"}],
      "steps" => [%{"order" => 1, "phase" => "COOKING", "action" => "Simmer.", "ingredients" => []}],
      "tags" => ["vegetarian"]
    }
  end

  # The planner: first turn resolves the recipe, second turn generates.
  defp stub_planner_turns(recipe_title) do
    Tore.MockLLM
    |> expect(:chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok,
       {:tool_calls,
        [%{id: "c1", name: "resolve_recipe", args: %{"query" => recipe_title}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)
    |> expect(:chat_with_tools, fn _sys, msgs, _tools, _opts ->
      ref = extract_ref(msgs)

      {:ok,
       {:tool_calls,
        [
          %{
            id: "c2",
            name: "generate_recipe_variant",
            args: %{
              "recipe_ref" => ref,
              "instruction" => "make it vegetarian",
              "slot_key" => "mon_dinner",
              "servings" => 4
            }
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)
    |> expect(:text, fn _sys, _user, _opts ->
      {:ok, variant_payload(), %{prompt_tokens: 10, completion_tokens: 20, cost_usd: 0.001}}
    end)
  end

  defp extract_ref(messages) do
    messages
    |> Enum.find(&(&1[:role] == "tool" || &1["role"] == "tool"))
    |> then(fn msg -> Jason.decode!(msg[:content] || msg["content"]) end)
    |> get_in(["match", "ref"])
  end

  test "a variant request parks the run in :needs_user with the proposal attached", ctx do
    recipe = source_recipe()
    stub_planner_turns(recipe.title)

    assert {:ok, %State.NeedsUser{} = state} =
             Orchestrator.dispatch(:planner_command_run, %{
               household_id: ctx.household.id,
               user_id: nil,
               command: "make tonight's ramen vegetarian",
               plan_stream_id: ctx.plan_stream_id,
               week_start: ~D[2026-08-17]
             })

    assert [%RecipeProposal{} = proposal] =
             Enum.filter(state.artifacts, &match?(%RecipeProposal{}, &1))

    assert proposal.title == "Vegetarian Miso Ramen"
    assert proposal.source == :generation
    assert state.question =~ "Review"
  end

  test "the pending slot assignment rides on the proposal artifact", ctx do
    recipe = source_recipe()
    stub_planner_turns(recipe.title)

    {:ok, %State.NeedsUser{artifacts: artifacts}} =
      Orchestrator.dispatch(:planner_command_run, %{
        household_id: ctx.household.id,
        user_id: nil,
        command: "make tonight's ramen vegetarian",
        plan_stream_id: ctx.plan_stream_id,
        week_start: ~D[2026-08-17]
      })

    assert [%RecipeProposal{pending_assignment: pending}] =
             Enum.filter(artifacts, &match?(%RecipeProposal{}, &1))

    assert pending == %{slot_key: "mon_dinner", servings: 4}
  end

  test "a proposal failing the verifier fails the run instead of parking it", ctx do
    recipe = source_recipe()

    Tore.MockLLM
    |> expect(:chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "resolve_recipe", args: %{"query" => recipe.title}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)
    |> expect(:chat_with_tools, fn _, msgs, _, _ ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c2",
            name: "generate_recipe_variant",
            args: %{"recipe_ref" => extract_ref(msgs), "instruction" => "simpler"}
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)
    |> expect(:text, fn _, _, _ ->
      # No ingredients — the verifier must reject this.
      {:ok,
       %{"title" => "Empty Ramen", "base_servings" => 4, "ingredients" => [], "steps" => []},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    assert {:ok, %State.Failed{} = state} =
             Orchestrator.dispatch(:planner_command_run, %{
               household_id: ctx.household.id,
               user_id: nil,
               command: "simpler ramen",
               plan_stream_id: ctx.plan_stream_id,
               week_start: ~D[2026-08-17]
             })

    assert state.code == :no_ingredients
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/harness/recipe_proposal_run_test.exs`
Expected: FAIL — `close/4` has no clause matching `{:proposal, _, _}`, so the run raises `FunctionClauseError` and `run_dispatch/4` returns `{:error, {:run_crashed, _}}`.

- [ ] **Step 3: Add the close branch**

In `lib/tore/harness/orchestrator.ex`, add a `close/4` clause next to the existing `{:question, q}` one:

```elixir
  defp close(state, %{result: {:proposal, proposal, pending}}, _ctx, metadata),
    do: verify_and_surface_proposal(state, proposal, pending, metadata)
```

And the implementation, next to `verify_and_surface_receipt/4`:

```elixir
  # SPEC §A.6.1: generated or imported recipe content never auto-commits. When
  # the verifier passes we park the run in :needs_user so the user reviews the
  # recipe on an editable card; commit_recipe_proposal/3 does the saving.
  defp verify_and_surface_proposal(state, %RecipeProposal{} = proposal, pending, metadata) do
    # The pending slot rides on the artifact: it is only known mid-loop, after
    # Commands.Open already wrote the run's input, and there is no command for
    # amending input.
    proposal = %{proposal | pending_assignment: normalise_pending(pending)}

    with :ok <- RecipeProposalVerifier.verify(proposal, recipe_proposal_ctx()),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AddArtifact{artifact: proposal},
             state,
             metadata
           ) do
      apply_command(
        state.stream_id,
        %Commands.RaiseQuestion{question: "Review this recipe before saving it."},
        state,
        metadata
      )
    else
      {:fail, code, repair} ->
        apply_command(
          state.stream_id,
          %Commands.RecordFailure{
            code: code,
            user_message: proposal_failure_message(code),
            repair_action: repair
          },
          state,
          metadata
        )

      other ->
        other
    end
  end

  defp proposal_failure_message(:near_duplicate),
    do: "You already have a recipe just like this one."

  defp proposal_failure_message(_code),
    do: "That recipe came back incomplete — nothing was saved."

  # An empty map means the planner asked for a recipe with no slot in mind.
  defp normalise_pending(pending) when pending == %{}, do: nil
  defp normalise_pending(pending), do: pending

  # The verifier is pure, so the catalog it compares against is gathered here.
  defp recipe_proposal_ctx do
    %{existing_recipes: Recipes.catalog_fingerprints()}
  end
```

The `pending_assignment` field this writes to was defined on the artifact back in Task 1.


- [ ] **Step 4: Add the catalog fingerprint query**

The verifier needs the catalog as `%{title:, ingredient_names:}`. Add to `lib/tore/recipes.ex`:

```elixir
  @doc """
  Titles and ingredient names for every recipe, for duplicate detection.
  Keeps `RecipeProposalVerifier` pure — it compares against this, it does not
  query.
  """
  @spec catalog_fingerprints() :: [%{title: String.t(), ingredient_names: [String.t()]}]
  def catalog_fingerprints do
    from(r in Recipe,
      left_join: ri in RecipeIngredient,
      on: ri.recipe_id == r.id,
      left_join: i in Ingredient,
      on: i.id == ri.ingredient_id,
      group_by: r.id,
      select: %{title: r.title, ingredient_names: fragment("group_concat(?, '')", i.name)}
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      %{row | ingredient_names: split_names(row.ingredient_names)}
    end)
  end

  defp split_names(nil), do: []
  defp split_names(joined), do: String.split(joined, "")
```

Add a test in `test/tore/recipes_test.exs`:

```elixir
  test "catalog_fingerprints/0 returns titles with their ingredient names" do
    {:ok, _} =
      Tore.Recipes.create(%{
        title: "Miso Ramen",
        base_servings: 4,
        ingredients: [%{name: "miso paste"}, %{name: "ramen noodles"}]
      })

    assert [%{title: "Miso Ramen", ingredient_names: names}] = Tore.Recipes.catalog_fingerprints()
    assert Enum.sort(names) == ["miso paste", "ramen noodles"]
  end
```

- [ ] **Step 5: Wire up the aliases**

In `lib/tore/harness/orchestrator.ex`, add `RecipeProposal` to the artifact alias list and `RecipeProposalVerifier` to the verifier alias list:

```elixir
  alias Tore.Harness.Verifier.{
    CostEntryVerifier,
    MemoryVerifier,
    PantryVerifier,
    PlanVerifier,
    RecipeProposalVerifier
  }

  alias Tore.Harness.Artifact.{
    CostEntry,
    MemoryUpdate,
    PantryBeliefUpdate,
    PlanDiff,
    RecipeProposal,
    RunBundle
  }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `mix test test/tore/harness/recipe_proposal_run_test.exs test/tore/recipes_test.exs test/tore/harness/orchestrator_test.exs`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(harness): park recipe proposals in :needs_user

close/4 gains a {:proposal, ...} branch: verify, attach the artifact, raise
the review question. Reuses the same machinery receipt runs already use.
Recipes.catalog_fingerprints/0 feeds duplicate detection without making the
verifier query.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 10: `commit_recipe_proposal/3`

The confirm side. Re-verify (the user may have edited the card), save the recipe, assign the slot if one was pending, and commit the run. Mirrors `commit_receipt/4`.

**Files:**

- Modify: `lib/tore/harness/orchestrator.ex`
- Test: `test/tore/harness/recipe_proposal_commit_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/tore/harness/recipe_proposal_commit_test.exs`:

```elixir
defmodule Tore.Harness.RecipeProposalCommitTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run.State

  setup do
    household = Tore.Household.get_household!()
    plan_stream_id = "plan:" <> Ecto.UUID.generate()
    {:ok, household: household, plan_stream_id: plan_stream_id}
  end

  defp proposal(overrides \\ %{}) do
    base = %RecipeProposal{
      title: "Vegetarian Miso Ramen",
      description: "No pork.",
      instructions: "Simmer the broth. Add tofu.",
      base_servings: 4,
      prep_time_minutes: 10,
      cook_time_minutes: 20,
      ingredients: [
        %{name: "miso paste", quantity: "2", unit: "msk"},
        %{name: "firm tofu", quantity: "300", unit: "g"}
      ],
      tags: ["vegetarian"],
      source: :generation,
      source_recipe_id: nil,
      instruction: "make it vegetarian",
      pending_assignment: nil
    }

    struct!(base, overrides)
  end

  # Drive a run to :needs_user by having the planner call a proposal tool.
  defp needs_user_run(ctx, proposal) do
    proposal_tool = %Tore.LLM.Tool{
      name: "fake_proposal_tool",
      description: "test double",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _args, _c, plan ->
        {:proposal, proposal, proposal.pending_assignment || %{}, plan}
      end
    }

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "fake_proposal_tool", args: %{}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, %State.NeedsUser{} = state} =
      Orchestrator.dispatch(:planner_command_run, %{
        household_id: ctx.household.id,
        user_id: nil,
        command: "make it vegetarian",
        plan_stream_id: ctx.plan_stream_id,
        week_start: ~D[2026-08-17],
        extra_tools: [proposal_tool]
      })

    state
  end

  test "committing saves the recipe to the catalog", ctx do
    state = needs_user_run(ctx, proposal())

    assert {:ok, %State.Applied{}} =
             Orchestrator.commit_recipe_proposal(state.stream_id, proposal(), nil)

    assert [recipe] = Tore.Recipes.list()
    assert recipe.title == "Vegetarian Miso Ramen"
    assert length(recipe.recipe_ingredients) == 2
  end

  test "committing with a pending assignment slots the new recipe", ctx do
    pending = %{slot_key: "mon_dinner", servings: 4}
    p = proposal(%{pending_assignment: pending})
    state = needs_user_run(ctx, p)

    assert {:ok, %State.Applied{}} =
             Orchestrator.commit_recipe_proposal(state.stream_id, p, nil)

    {:ok, plan} = Tore.Planning.load_plan(ctx.plan_stream_id)
    [recipe] = Tore.Recipes.list()

    assert get_in(plan.slots, ["mon_dinner", :recipe_id]) == recipe.id
  end

  test "committing an edited proposal saves the edits, not the original", ctx do
    state = needs_user_run(ctx, proposal())

    edited = proposal(%{title: "Vegan Miso Ramen"})

    assert {:ok, %State.Applied{}} =
             Orchestrator.commit_recipe_proposal(state.stream_id, edited, nil)

    assert [%{title: "Vegan Miso Ramen"}] = Tore.Recipes.list()
  end

  test "committing an edit that fails the verifier saves nothing", ctx do
    state = needs_user_run(ctx, proposal())

    broken = proposal(%{ingredients: []})

    assert {:error, {:verifier_failed, :no_ingredients, :reject}} =
             Orchestrator.commit_recipe_proposal(state.stream_id, broken, nil)

    assert Tore.Recipes.list() == []
  end

  test "discarding saves nothing and leaves the slot untouched", ctx do
    pending = %{slot_key: "mon_dinner", servings: 4}
    p = proposal(%{pending_assignment: pending})
    state = needs_user_run(ctx, p)

    assert {:ok, %State.Discarded{}} =
             Orchestrator.discard_run(state.stream_id, reason: :user_discarded)

    assert Tore.Recipes.list() == []

    {:ok, plan} = Tore.Planning.load_plan(ctx.plan_stream_id)
    assert get_in(plan.slots, ["mon_dinner", :recipe_id]) == nil
  end

  test "committing a run that is not awaiting the user is rejected", ctx do
    state = needs_user_run(ctx, proposal())
    {:ok, _} = Orchestrator.commit_recipe_proposal(state.stream_id, proposal(), nil)

    assert {:error, :already_applied} =
             Orchestrator.commit_recipe_proposal(state.stream_id, proposal(), nil)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/tore/harness/recipe_proposal_commit_test.exs`
Expected: FAIL — `Orchestrator.commit_recipe_proposal/3 is undefined`.

- [ ] **Step 3: Implement the commit**

In `lib/tore/harness/orchestrator.ex`, next to `commit_receipt/4`:

```elixir
  @doc """
  Commit a recipe proposal after the user has reviewed (and possibly edited)
  it on the `:needs_user` card. Re-runs the verifier against the submitted
  proposal, saves the recipe to the catalog, and — if the run carried a
  pending slot assignment — assigns it. UI entrypoint; not part of
  `dispatch/2`.
  """
  @spec commit_recipe_proposal(String.t(), RecipeProposal.t(), integer() | nil) ::
          {:ok, State.t()} | {:error, term()}
  def commit_recipe_proposal(stream_id, %RecipeProposal{} = proposal, user_id) do
    {:ok, state} = Run.load(stream_id)
    metadata = %{household_id: state.household_id}

    with %State.NeedsUser{} <- state,
         :ok <- RecipeProposalVerifier.verify(proposal, recipe_proposal_ctx()),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AnswerQuestion{answer: "confirmed"},
             state,
             metadata
           ),
         {:ok, recipe} <- Recipes.create(recipe_attrs(proposal, user_id)),
         :ok <- assign_pending_slot(state, proposal, recipe),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AddArtifact{artifact: proposal},
             state,
             metadata
           ),
         run_summary = RunSummary.from_artifacts([proposal], :applied),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AddArtifact{artifact: run_summary},
             state,
             metadata
           ) do
      apply_command(state.stream_id, commit_command(state), state, metadata)
    else
      %State.Running{} -> {:error, :not_awaiting_user}
      %State.Applied{} -> {:error, :already_applied}
      %State.Failed{} -> {:error, :already_failed}
      %State.Discarded{} -> {:error, :already_discarded}
      {:fail, code, repair} -> {:error, {:verifier_failed, code, repair}}
      other -> {:error, other}
    end
  end

  defp recipe_attrs(%RecipeProposal{} = proposal, user_id) do
    %{
      title: proposal.title,
      description: proposal.description,
      instructions: proposal.instructions,
      base_servings: proposal.base_servings,
      prep_time_minutes: proposal.prep_time_minutes,
      cook_time_minutes: proposal.cook_time_minutes,
      source_url: proposal.source_url,
      created_by: user_id,
      tags: proposal.tags,
      ingredients: Enum.map(proposal.ingredients, &recipe_ingredient_attrs/1)
    }
  end

  defp recipe_ingredient_attrs(ing) do
    %{name: ing[:name], quantity: to_decimal_quantity(ing[:quantity]), unit: ing[:unit]}
  end

  defp to_decimal_quantity(nil), do: nil
  defp to_decimal_quantity(%Decimal{} = d), do: d

  defp to_decimal_quantity(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _rest} -> d
      :error -> nil
    end
  end

  defp to_decimal_quantity(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal_quantity(n) when is_float(n), do: Decimal.from_float(n)

  defp assign_pending_slot(_state, %RecipeProposal{pending_assignment: nil}, _recipe), do: :ok

  defp assign_pending_slot(state, %RecipeProposal{pending_assignment: pending}, recipe) do
    plan_stream_id = run_input(state, :plan_stream_id)

    with {:ok, plan} <- Planning.load_plan(plan_stream_id),
         cmd = %Planning.Commands.AssignRecipe{
           slot_key: pending[:slot_key] || pending["slot_key"],
           recipe_id: recipe.id,
           servings: pending[:servings] || pending["servings"] || recipe.base_servings || 4
         },
         {:ok, events} <- Planning.Decider.decide(cmd, plan) do
      Planning.apply_events(plan_stream_id, events)
    end
  end

  defp run_input(%{input: input}, key) do
    Map.get(input, key) || Map.get(input, Atom.to_string(key))
  end
```

Add `alias Tore.Planning.Decider` only if `Planning.Decider` is not already reachable — the module already aliases `Tore.Planning`, so `Planning.Decider` and `Planning.Commands` resolve without a new alias.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/tore/harness/recipe_proposal_commit_test.exs`
Expected: all 6 tests pass.

If the "already_applied" test fails because `Run.load/1` returns a `Discarded`/`Applied` state that the `with` head does not match, check the `else` clauses cover the state the run is actually in — the clause list above covers Running, Applied, Failed, and Discarded.

- [ ] **Step 5: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(harness): commit_recipe_proposal/3

Confirm side of the :needs_user card: re-verify the (possibly edited)
proposal, save the recipe, assign the pending slot. Discard still saves
nothing.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 11: Surface the proposal card in the UI

`RunReviewLive` already renders `:needs_user` runs for receipts. Add the recipe-proposal case so the user can actually confirm or discard.

**Files:**

- Modify: `lib/tore_web/live/run_review_live.ex`
- Modify: `lib/tore_web/live/inbox_live.ex`
- Test: `test/tore_web/live/run_review_recipe_test.exs`

- [ ] **Step 1: Read the existing LiveView**

Read `lib/tore_web/live/run_review_live.ex` in full — particularly `extract_artifacts/1` (line 389), the `mount/3` clause at line 26, the discard handler at line 104, and the commit handler at line 124. The recipe case follows the same shape; do not restructure the receipt path.

- [ ] **Step 2: Write the failing test**

Create `test/tore_web/live/run_review_recipe_test.exs`:

```elixir
defmodule ToreWeb.RunReviewRecipeTest do
  use ToreWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run.State

  setup do
    household = Tore.Household.get_household!()
    {:ok, household: household, plan_stream_id: "plan:" <> Ecto.UUID.generate()}
  end

  defp proposal do
    %RecipeProposal{
      title: "Vegetarian Miso Ramen",
      instructions: "Simmer the broth.",
      base_servings: 4,
      ingredients: [%{name: "firm tofu", quantity: "300", unit: "g"}],
      tags: ["vegetarian"],
      source: :generation,
      instruction: "make it vegetarian",
      pending_assignment: nil
    }
  end

  defp needs_user_run(ctx) do
    p = proposal()

    proposal_tool = %Tore.LLM.Tool{
      name: "fake_proposal_tool",
      description: "test double",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _args, _c, plan -> {:proposal, p, %{}, plan} end
    }

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "fake_proposal_tool", args: %{}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, %State.NeedsUser{} = state} =
      Orchestrator.dispatch(:planner_command_run, %{
        household_id: ctx.household.id,
        user_id: nil,
        command: "make it vegetarian",
        plan_stream_id: ctx.plan_stream_id,
        week_start: ~D[2026-08-17],
        extra_tools: [proposal_tool]
      })

    state
  end

  test "the review page shows the proposed recipe", %{conn: conn} = ctx do
    state = needs_user_run(ctx)

    {:ok, _view, html} = live(conn, ~p"/runs/#{state.stream_id}/review")

    assert html =~ "Vegetarian Miso Ramen"
    assert html =~ "firm tofu"
  end

  test "confirming saves the recipe", %{conn: conn} = ctx do
    state = needs_user_run(ctx)

    {:ok, view, _html} = live(conn, ~p"/runs/#{state.stream_id}/review")

    view |> element("button", "Save") |> render_click()

    assert [%{title: "Vegetarian Miso Ramen"}] = Tore.Recipes.list()
  end

  test "discarding saves nothing", %{conn: conn} = ctx do
    state = needs_user_run(ctx)

    {:ok, view, _html} = live(conn, ~p"/runs/#{state.stream_id}/review")

    view |> element("button", "Discard") |> render_click()

    assert Tore.Recipes.list() == []
  end
end
```

Adjust the route (`~p"/runs/#{id}/review"`) and the button labels to whatever `lib/tore_web/live/run_review_live.ex` and `lib/tore_web/router.ex` actually use — read them first and match the existing receipt flow's markup exactly.

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/tore_web/live/run_review_recipe_test.exs`
Expected: FAIL — the page renders the receipt branch (or crashes) because no clause handles a `RecipeProposal`.

- [ ] **Step 4: Add the recipe branch**

In `lib/tore_web/live/run_review_live.ex`:

Extend `extract_artifacts/1` to recognise the proposal:

```elixir
  defp extract_artifacts(%State.NeedsUser{artifacts: artifacts}) do
    %{
      cost: Enum.find(artifacts, &match?(%CostEntry{}, &1)),
      pantry: Enum.find(artifacts, &match?(%PantryBeliefUpdate{}, &1)),
      recipe_proposal: Enum.find(artifacts, &match?(%RecipeProposal{}, &1))
    }
  end
```

(keep whatever shape the function already returns; add the `:recipe_proposal` key alongside.)

Add a render branch that shows title, servings, ingredients, and instructions, with Save and Discard buttons — follow the receipt card's markup and Tailwind classes so the two cards look like one system. Per the project UI doctrine, the card states what will happen ("Save this recipe to your catalog"), not what the system did.

Add the commit handler next to the existing one:

```elixir
  def handle_event("save_recipe", _params, socket) do
    %{stream_id: stream_id, recipe_proposal: proposal, user_id: user_id} = socket.assigns

    case Orchestrator.commit_recipe_proposal(stream_id, proposal, user_id) do
      {:ok, _state} ->
        {:noreply, socket |> put_flash(:info, "Recipe saved.") |> push_navigate(to: ~p"/")}

      {:error, {:verifier_failed, code, _repair}} ->
        {:noreply, put_flash(socket, :error, verifier_message(code))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't save that recipe.")}
    end
  end

  defp verifier_message(:near_duplicate), do: "You already have a recipe just like this one."
  defp verifier_message(:no_ingredients), do: "That recipe has no ingredients."
  defp verifier_message(_), do: "That recipe came back incomplete."
```

The existing discard handler at line 104 already works for any `:needs_user` run — reuse it, do not duplicate.

In `lib/tore_web/live/inbox_live.ex`, add a `label_for/1` clause so the run reads sensibly in the inbox, placed before the catch-all `label_for(%State.NeedsUser{kind: kind})`:

```elixir
  defp label_for(%State.NeedsUser{kind: "planner_command_run", artifacts: artifacts}) do
    case Enum.find(artifacts, &match?(%RecipeProposal{}, &1)) do
      %RecipeProposal{title: title} -> "New recipe: #{title}"
      nil -> "Planner"
    end
  end
```

Add `alias Tore.Harness.Artifact.RecipeProposal` to both LiveViews.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/tore_web/live/run_review_recipe_test.exs test/tore_web/`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(web): recipe proposal review card

RunReviewLive renders a RecipeProposal on the :needs_user card with Save
and Discard; the inbox names the run by the proposed recipe.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 12: Web-find end to end

An integration test proving the whole discovery → import → confirm path, with the scraper's HTTP stubbed. This is the flow no earlier task covers end to end.

**Files:**

- Test: `test/tore/harness/recipe_web_find_test.exs`

- [ ] **Step 1: Write the test**

Create `test/tore/harness/recipe_web_find_test.exs`:

```elixir
defmodule Tore.Harness.RecipeWebFindTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run.State

  setup do
    household = Tore.Household.get_household!()
    {:ok, household: household, plan_stream_id: "plan:" <> Ecto.UUID.generate()}
  end

  @page_html """
  <html><head><script type="application/ld+json">
  {"@type":"Recipe","name":"Best Miso Ramen",
   "recipeIngredient":["2 msk miso paste","4 portioner ramen noodles"],
   "recipeInstructions":[{"@type":"HowToStep","text":"Simmer the broth."},
                         {"@type":"HowToStep","text":"Cook the noodles."}],
   "recipeYield":"4"}
  </script></head><body></body></html>
  """

  test "find on the web, import the chosen page, confirm, and it lands in the catalog", ctx do
    # Turn 1: the planner searches.
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "find_recipe_web", args: %{"query" => "miso ramen"}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    expect(Tore.MockLLM, :web_search, fn _system, _user, _opts ->
      {:ok,
       %{"candidates" => [%{"title" => "Best Miso Ramen", "url" => "https://example.com/ramen"}]},
       %{prompt_tokens: 10, completion_tokens: 5, cost_usd: 0.001}}
    end)

    # Turn 2: the planner imports the candidate it picked.
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c2",
            name: "import_recipe_from_web",
            args: %{"url" => "https://example.com/ramen"}
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    expect(Tore.MockHTTP, :fetch, fn "https://example.com/ramen" -> {:ok, @page_html} end)

    assert {:ok, %State.NeedsUser{} = state} =
             Orchestrator.dispatch(:planner_command_run, %{
               household_id: ctx.household.id,
               user_id: nil,
               command: "find me a good miso ramen recipe",
               plan_stream_id: ctx.plan_stream_id,
               week_start: ~D[2026-08-17]
             })

    assert [%RecipeProposal{} = proposal] =
             Enum.filter(state.artifacts, &match?(%RecipeProposal{}, &1))

    assert proposal.source == :web_import
    assert proposal.source_url == "https://example.com/ramen"

    # Nothing saved before the user confirms.
    assert Tore.Recipes.list() == []

    assert {:ok, %State.Applied{}} =
             Orchestrator.commit_recipe_proposal(state.stream_id, proposal, nil)

    assert [recipe] = Tore.Recipes.list()
    assert recipe.title =~ "Ramen"
    assert recipe.source_url == "https://example.com/ramen"
  end

  test "no search results means no proposal and a plain answer", ctx do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok,
       {:tool_calls, [%{id: "c1", name: "find_recipe_web", args: %{"query" => "unobtainium stew"}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    expect(Tore.MockLLM, :web_search, fn _, _, _ ->
      {:ok, %{"candidates" => []}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "I couldn't find a recipe for that."},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    assert {:ok, state} =
             Orchestrator.dispatch(:planner_command_run, %{
               household_id: ctx.household.id,
               user_id: nil,
               command: "find me an unobtainium stew recipe",
               plan_stream_id: ctx.plan_stream_id,
               week_start: ~D[2026-08-17]
             })

    refute match?(%State.NeedsUser{}, state)
    assert Tore.Recipes.list() == []
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/tore/harness/recipe_web_find_test.exs`
Expected: PASS. Everything it needs already exists after Tasks 1–10; this test is the proof.

If the JSON-LD fixture does not parse, read `parse_or_extract/2` in `lib/tore/recipes.ex` and either match the shape it expects or add a `Tore.MockLLM.text/3` expectation for the HTML-extraction fallback.

- [ ] **Step 3: Commit**

```bash
jj describe -m "$(cat <<'EOF'
test(harness): web-find flow end to end

Search, import the chosen page, park in :needs_user, confirm, land in the
catalog. Nothing is saved before confirmation.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 13: Expose both capabilities from Capture

The design says both are "reusable from Capture". Capture's `Dispatch.find_recipe/1` searches the local catalog only; when it comes up empty, offer the web.

**Files:**

- Modify: `lib/tore/capture/dispatch.ex`
- Test: `test/tore/capture/dispatch_web_find_test.exs`

- [ ] **Step 1: Read the current behaviour**

Read `lib/tore/capture/dispatch.ex:163-193` (`find_recipe/1`) and `lib/tore/capture/router.ex` to see how intents route to it. The no-match bubble today says: *"I couldn't find a recipe matching "%{q}". Want me to import one from a URL?"*

- [ ] **Step 2: Write the failing test**

Create `test/tore/capture/dispatch_web_find_test.exs`:

```elixir
defmodule Tore.Capture.DispatchWebFindTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Capture.Dispatch

  test "find_recipe_on_web/1 returns candidates the user can pick from" do
    expect(Tore.MockLLM, :web_search, fn _system, _user, _opts ->
      {:ok,
       %{
         "candidates" => [
           %{"title" => "Best Miso Ramen", "url" => "https://example.com/ramen"},
           %{"title" => "Quick Ramen", "url" => "https://example.com/quick"}
         ]
       }, %{prompt_tokens: 10, completion_tokens: 5, cost_usd: 0.001}}
    end)

    bubble = Dispatch.find_recipe_on_web("miso ramen")

    assert bubble.web_candidates == [
             %{title: "Best Miso Ramen", url: "https://example.com/ramen"},
             %{title: "Quick Ramen", url: "https://example.com/quick"}
           ]
  end

  test "find_recipe_on_web/1 says so when the web has nothing" do
    expect(Tore.MockLLM, :web_search, fn _, _, _ ->
      {:ok, %{"candidates" => []}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    bubble = Dispatch.find_recipe_on_web("unobtainium stew")

    assert bubble.text =~ "couldn't find"
    refute Map.has_key?(bubble, :web_candidates)
  end

  test "find_recipe_on_web/1 reports a resting search rather than an error" do
    Tore.Costs.log_llm_usage(%{
      feature: "recipe_web_search",
      prompt_tokens: 1,
      completion_tokens: 1,
      cost_usd: Decimal.new("0.0001")
    })

    bubble = Dispatch.find_recipe_on_web("ramen")

    assert bubble.text =~ "resting"
  end

  test "find_recipe/1 with no local match offers the web" do
    bubble = Dispatch.find_recipe("nothing matches this")

    assert bubble.text =~ "web"
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/tore/capture/dispatch_web_find_test.exs`
Expected: FAIL — `Tore.Capture.Dispatch.find_recipe_on_web/1 is undefined`.

- [ ] **Step 4: Add the Capture path**

In `lib/tore/capture/dispatch.ex`, after `find_recipe/1`:

```elixir
  @doc """
  Search the web for recipe pages. Discovery only — the user picks a
  candidate and the existing URL-import path parses it.
  """
  @spec find_recipe_on_web(String.t()) :: bubble()
  def find_recipe_on_web(query) when is_binary(query) do
    case Tore.SpendGuard.allow?(:recipe_web_search) do
      :ok -> do_web_search(query)
      {:error, _} -> %{role: :assistant, text: guard_text()}
    end
  end

  defp do_web_search(query) do
    locale = household_locale()
    {system, user} = Tore.LLM.Prompts.find_recipe_web(query, locale)

    case Tore.LLM.web_search(system, user,
           response_format: Tore.LLM.Prompts.web_candidates_json_schema()
         ) do
      {:ok, %{"candidates" => []}, usage} ->
        Tore.SpendGuard.log_usage(:recipe_web_search, usage)
        %{role: :assistant, text: no_web_match_text(query)}

      {:ok, %{"candidates" => candidates}, usage} ->
        Tore.SpendGuard.log_usage(:recipe_web_search, usage)

        %{
          role: :assistant,
          web_candidates: Enum.map(candidates, &%{title: &1["title"], url: &1["url"]}),
          text:
            Gettext.dgettext(ToreWeb.Gettext, "default", "Here's what I found. Pick one to import.")
        }

      {:error, _reason} ->
        %{
          role: :assistant,
          text: Gettext.dgettext(ToreWeb.Gettext, "default", "The search didn't come back. Try again in a moment.")
        }
    end
  end

  defp no_web_match_text(query) do
    Gettext.dgettext(
      ToreWeb.Gettext,
      "default",
      "I couldn't find a recipe for \"%{q}\" on the web either.",
      q: query
    )
  end

  defp guard_text do
    Gettext.dgettext(
      ToreWeb.Gettext,
      "default",
      "Web search is resting — try again shortly."
    )
  end
```

Change the no-match branch of `find_recipe/1` to offer the web instead of only a URL:

```elixir
      [] ->
        %{
          role: :assistant,
          offer_web_search: true,
          query: query,
          text:
            Gettext.dgettext(
              ToreWeb.Gettext,
              "default",
              "I couldn't find a recipe matching \"%{q}\" in your catalog. Want me to look on the web?",
              q: query
            )
        }
```

If `household_locale/0` does not already exist in this module, add it:

```elixir
  defp household_locale do
    case Tore.Household.get_household!() do
      %{locale: locale} when is_binary(locale) -> locale
      _ -> nil
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/tore/capture/`
Expected: all pass. If an existing dispatch test asserts the old no-match wording, update that assertion to the new text.

- [ ] **Step 6: Commit**

```bash
jj describe -m "$(cat <<'EOF'
feat(capture): offer web recipe search when the catalog has no match

find_recipe/1's empty result now offers the web; find_recipe_on_web/1
returns candidates the user picks from, then the existing URL import runs.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

---

### Task 14: SPEC.md amendments and full verification

**Files:**

- Modify: `SPEC.md`

- [ ] **Step 1: Run the whole suite**

Run: `mix test`
Expected: green. A "Database busy" SQLite error under parallel load is the known pre-existing flake — re-run the failing file alone to confirm it passes in isolation before treating it as a real failure.

- [ ] **Step 2: Run the compiler with warnings as errors**

Run: `mix compile --warnings-as-errors --force`
Expected: no warnings. Unused aliases and functions from the refactors are the likely offenders — fix them rather than silencing them.

- [ ] **Step 3: Format**

Run: `mix format && jj diff --stat`
Expected: formatting-only changes, if any.

- [ ] **Step 4: Amend SPEC.md**

Make these edits (find each section by its heading):

1. **§2 planner tool list** — add to the tool table/list:
   - `find_recipe_web` — search the web for candidate recipe pages (discovery only).
   - `import_recipe_from_web` — parse a chosen URL into a `RecipeProposal`.
   - `generate_recipe_variant` — generate a variant of an existing recipe as a `RecipeProposal`.

2. **§A.3 artifacts** — change `RecipeProposal` from `PLANNED` to `SHIPPED` and add the note: *"`source ∈ {:web_import, :generation}`; carries provenance (source URL for imports, source recipe id + instruction for variants) and an optional `pending_assignment` slot."*

3. **§A.5 verifiers** — change `RecipeProposalVerifier` from `PLANNED` to `SHIPPED` and list the fail codes: `:missing_title`, `:no_ingredients`, `:empty_ingredient_name`, `:missing_instructions`, `:invalid_servings`, `:near_duplicate`.

4. **§A.6.1 tiers** — under Tier 3, add: *"`generate_recipe_variant` and `import_recipe_from_web` are the in-planner generation/ingestion paths. They end the planner loop with a `{:proposal, …}` signal and park the parent `:planner_command_run` in `:needs_user` — one run, one receipt, one undo. `Orchestrator.commit_recipe_proposal/3` is the confirm gate."*

5. **Status log** — add an entry dated the day you finish:
   ```
   ### 2026-08-DD — Recipe intelligence
   Web recipe discovery and recipe transformation land. Both are planner read
   tools producing a `RecipeProposal` the user confirms on a `:needs_user`
   card. Web search runs through OpenRouter's `web` plugin (no dependency
   change) under a `:recipe_web_search` spend budget. Fridge rescue (§6)
   remains the open hole.
   ```

- [ ] **Step 5: Commit**

```bash
jj describe -m "$(cat <<'EOF'
docs(spec): recipe intelligence amendments

RecipeProposal and RecipeProposalVerifier ship; three new planner tools;
Tier 3 confirm gate documented.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
EOF
)"
jj new
```

- [ ] **Step 6: Push**

Per project convention, this goes to master.

```bash
jj bookmark set master -r @-
jj git push --bookmark master
```

---

## Verification checklist

Before claiming the feature is done, run each of these and confirm the output:

- [ ] `mix test` — full suite green.
- [ ] `mix compile --warnings-as-errors --force` — no warnings.
- [ ] `mix format --check-formatted` — clean.
- [ ] `mix test test/tore/harness/recipe_web_find_test.exs` — the web-find flow proof.
- [ ] `mix test test/tore/harness/recipe_proposal_commit_test.exs` — confirm saves, discard does not.

Do not claim completion on any of these without having run the command and read its output.

## What this plan deliberately does not build

- **§6 fridge rescue** (`:fridge_rescue_run`) — a separate spec (D4).
- **Ephemeral "cook once without saving" recipes** — D1 chose catalog-only.
- **Model-synthesized recipe bodies from search snippets** — D2 chose scrape-the-URL; `find_recipe_web` is discovery only and the prompt says so.
- **A separate child run kind for generation** — D3 chose the parent-run pause.
