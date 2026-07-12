# Recipe Intelligence — Design Spec

> **Status:** Approved design (brainstorming output). Next step: implementation plan (Plan 4) via `superpowers:writing-plans`.
> **Date:** 2026-08-17
> **Scope owner:** extends SPEC.md §2 (planner), §A.3 (artifacts), §A.5 (verifiers), §A.6.1 (tiers).

## Goal

Give Tore two new recipe capabilities, both driven from the planner command bar (and reusable from Capture):

1. **Web-search recipe finding** — "find me a good ramen recipe" → OpenRouter web search discovers candidate URLs → the chosen URL flows through the **existing** `scrape_from_url` → parse → proposal pipeline.
2. **Recipe transformation / generation** — "make a simpler version of tonight's", "something like this but vegetarian", "make it for 6" → the planner generates a **new catalog recipe** (Tier 3, explicit confirm) → assigns it to the slot.

Both produce a `RecipeProposal` the user reviews before anything enters the catalog. §6 fridge rescue is **out of scope** — separate follow-up spec.

## Decisions (locked during brainstorming)

| # | Decision |
|---|---|
| D1 | A transformed/generated recipe becomes a **new catalog recipe**, then is slotted. Not ephemeral. |
| D2 | Web search does **discovery only**. The chosen URL is parsed by the **existing** `scrape_from_url → RecipeProposal` pipeline. The model does not synthesize recipe bodies from snippets. |
| D3 | Generation confirm flow: planner proposes mid-loop, the **parent `:planner_command_run` pauses `:needs_user`**. One run, one receipt, one undo. No separate child run kind. |
| D4 | Scope = web-find + transform only. Fridge rescue (§6) is a separate spec. |
| D5 | Architecture = **Approach A**: both capabilities are planner **read tools**; the generation tool terminates the loop into `:needs_user` carrying a `RecipeProposal`. Generation IO stays out of the pure-proposal action-tool path. |

## Architecture (Approach A)

### Constraint that shapes everything

Planner **action** tools are pure proposals (`PlannerTools` moduledoc): `run` returns `{:ok, result, events, next_plan}` against an in-memory plan, **no IO, nothing persists**. Recipe generation and web search are IO (LLM calls, HTTP). Therefore they are **read tools**, not action tools — and the generation tool needs a runtime-recognized signal to end the loop into `:needs_user`.

### New planner read tools

- **`find_recipe_web(query)`** — read tool. Runs the OpenRouter web search (see "Web search" below), returns up to 5 candidates as `{title, url}` handles. The planner picks one and calls the existing URL-import path to produce a `RecipeProposal`. Discovery only (D2).
- **`generate_recipe_variant(recipe_ref, instruction)`** — read tool. `recipe_ref` is a handle from `resolve_recipe`/`search_recipes`/`resolve_slot`'s assigned recipe; `instruction` is free text ("simpler", "vegetarian", "for 6"). Its `run` does a Pattern-A generation LLM call seeded with the source recipe, produces a `RecipeProposal`, and returns a **loop-terminating signal** the PlannerAgent runtime recognizes (e.g. `{:proposal, %RecipeProposal{...}}`).

### Loop-terminating proposal signal

PlannerAgent's runtime gains one new branch: when a read tool returns `{:proposal, proposal}`, the loop stops (no further round-trips), the proposal is attached to the run, and the run transitions **`:needs_user`** — reusing the existing `:needs_user` + `commit_after_review` machinery that receipt/pantry runs already use (orchestrator.ex:418). A pending slot assignment (the slot the variant was for) is carried on the run so that, on confirm, the harness: (1) saves the recipe to the catalog, (2) assigns it to the slot. On discard, nothing is saved.

### New artifact + verifier (do not exist yet — must be built)

SPEC §A.3 and §A.5 list `RecipeProposal` and `RecipeProposalVerifier` but neither is in the tree. This design builds them:

- **`RecipeProposal` artifact** — carries the parsed-or-generated recipe (title, ingredients ≥1, instructions, servings > 0), a `source` (`:web_import` | `:generation`), provenance (source URL for imports; source recipe id + instruction for variants), and a `RunSummary`. Editable on the `:needs_user` card.
- **`RecipeProposalVerifier`** — per SPEC §A.5: title present; ≥1 ingredient, no empty ingredient names; instructions present; servings positive; **no near-duplicate** of an existing catalog recipe (title + ingredient-overlap heuristic). Failure → repair state with `user_message`.

### Web search (OpenRouter, no lib change)

`OpenRouter.chat_completions/3` passes an arbitrary `body` map straight to `Req.post(json: body)`, so web search is a body-only feature — **no `open_router` dep change**. Implementation: a new Pattern-A op in `Tore.LLM.Prompts` + a `Tore.LLM` call path that adds the web plugin to the body:

```elixir
body = %{model: ..., messages: [...], plugins: [%{id: "web", max_results: 5}]}
```

(OpenRouter routes web search to Exa under the hood — so this *replaces* holding a direct Exa key, billed through OpenRouter.) The op returns candidate `{title, url}` list; that's the discovery result. Gated by `SpendGuard` under a new feature key (e.g. `:recipe_web_search`) with its own token budget + cooldown, consistent with `:ambient_scan`'s `{8_000, 600}` pattern.

### Tiers & routing

- `generate_recipe_variant` → the generation is Tier 3 (§A.6.1: invented content never auto-commits). The `:needs_user` pause **is** the Tier-3 confirm gate.
- `find_recipe_web` → discovery is Tier 0 (read-only). The subsequent URL import is the existing Tier-2 ingestion path (already surfaces a proposal card).
- Model tiers: web-search op = cheap structured + web plugin; generation = strong (invents structured content). No per-call override beyond the declared tiers (§A.8).

## Data flow

**Web find:** command bar → `:planner_command_run` → planner calls `find_recipe_web(query)` → candidates → planner calls existing URL-import → `RecipeProposal` (`source: :web_import`) → `RecipeProposalVerifier` → `:needs_user` card → confirm → recipe saved + (if slotting intent) assigned.

**Transform:** command bar "simpler version of tonight" → `:planner_command_run` → `resolve_slot("tonight")` gets the assigned recipe → `generate_recipe_variant(recipe_ref, "simpler")` → `{:proposal, ...}` terminates loop → `RecipeProposal` (`source: :generation`) → verifier → `:needs_user` → confirm → new recipe saved to catalog + assigned to the slot.

## Error handling

- Web search returns nothing / no scrapable URL → planner surfaces "couldn't find a recipe for X" (reuses `find_recipe` no-match phrasing); no proposal.
- Scrape of chosen URL fails → existing `import_recipe_from_url` error bubbles (`:not_a_recipe`, `:timeout`).
- `RecipeProposalVerifier` fails (e.g. near-duplicate, empty ingredient) → repair state with `user_message`, nothing saved.
- SpendGuard budget/cooldown hit on web search → graceful "search is resting, try again shortly" (consistent with existing guard messaging).
- User discards the `:needs_user` card → nothing enters the catalog, slot unchanged.

## Testing

- Unit: `RecipeProposalVerifier` (each failure code — empty ingredient, dup, zero servings, missing title).
- Unit: web-search prompt op returns `{title, url}` candidates from a stubbed `MockLLM`; body includes the web plugin.
- Unit: `generate_recipe_variant` tool returns `{:proposal, ...}`; PlannerAgent loop recognizes it and stops → `:needs_user`.
- Integration: transform flow end-to-end with `MockLLM` — resolve slot → generate → needs_user → commit saves recipe + assigns slot; discard saves nothing.
- Integration: web-find flow — find → import (existing scraper stubbed) → proposal → commit.
- Locale: generation and web-search prompts are English with household locale threaded as a parameter (per project convention).

## Out of scope / follow-ups

- **§6 fridge rescue** (`:fridge_rescue_run`) — the remaining hole in the Six Features. Next spec after this.
- Ephemeral "cook once without saving" recipes (D1 chose catalog-only).
- Model-synthesized recipe bodies from search snippets (D2 chose scrape-the-URL).
- `:deal_opportunity_run`, Skills catalog, remaining `PLANNED` verifiers — untouched.

## SPEC.md amendments this will require

- §2 planner tool list: add `find_recipe_web`, `generate_recipe_variant`.
- §A.3: mark `RecipeProposal` as **shipped**; note `source ∈ {:web_import, :generation}`.
- §A.5: mark `RecipeProposalVerifier` as **shipped**.
- §A.6.1 Tier 3: note `generate_recipe_variant` as the in-planner generation path pausing `:needs_user`.
- Status log entry dated at implementation time.
