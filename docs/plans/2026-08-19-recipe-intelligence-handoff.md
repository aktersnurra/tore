# Handoff — Recipe Intelligence (web-find + recipe transform)

**Date:** 2026-08-17
**Where we are:** Brainstorming complete + approved. Design spec written & committed. **Next step: write the implementation plan (Plan 4).** No implementation code written yet.

## Resume in one line

Read `docs/specs/2026-08-17-recipe-intelligence-design.md`, then invoke `superpowers:writing-plans` to produce `docs/plans/2026-08-<date>-recipe-intelligence.md`. Approach and all decisions are locked — do **not** re-brainstorm.

## What this feature is

Two planner capabilities, both surfaced from the plan command bar (and reusable from Capture):
1. **Web-search recipe finding** — web search discovers URLs; the chosen URL flows through the **existing** `scrape_from_url → RecipeProposal` pipeline (discovery only).
2. **Recipe transformation** — "simpler version of tonight", "like this but vegetarian", "for 6" → generate a **new catalog recipe** (Tier 3, explicit confirm) → slot it.

## Locked decisions (do not reopen)

- **D1** transformed recipe → saved as new catalog recipe, then slotted (not ephemeral).
- **D2** web search = discovery only; parse the chosen URL with the existing scraper (no model-synthesized bodies).
- **D3** generation confirm = parent `:planner_command_run` pauses `:needs_user`; one run/receipt/undo (no separate child run kind).
- **D4** scope = web-find + transform only; §6 fridge rescue is a separate later spec.
- **D5** Approach A: both are planner **read tools**; `generate_recipe_variant` returns a **loop-terminating** `{:proposal, ...}` signal → `:needs_user`. Generation IO stays out of the pure-proposal action path.

## Key facts verified in code (so the plan is honest)

- `RecipeProposal` artifact **and** `RecipeProposalVerifier` **do not exist yet** — SPEC lists them but they were never built. The plan must build both.
- `:needs_user` + `commit_after_review` plumbing **exists** (orchestrator.ex:418, used by receipt/pantry runs) — reuse it.
- Planner action tools are **pure proposals** (no IO) — see `PlannerTools` moduledoc. This is why generation/web-search must be read tools.
- `OpenRouter.chat_completions/3` passes `body` straight to `Req.post(json: body)` — web search is body-only, **no `open_router` dep change**. Add `plugins: [%{id: "web", max_results: 5}]` to the body.
- Existing planner tools: `assign_recipe, swap_recipe, skip_meal, mark_leftover, set_servings, remove_recipe, ask_user, search_recipes, resolve_recipe, resolve_slot, pantry_snapshot, active_deals` (`lib/tore/llm/planner_tools.ex`).
- Existing ingestion paths to reuse: `Tore.Recipes.scrape_from_url/2` (recipes.ex:100), `Dispatch.import_recipe_from_url/2` (dispatch.ex:146), `Dispatch.find_recipe/1` (local catalog only today).
- `SpendGuard` feature-defaults map at `lib/tore/spend_guard.ex:7` (`ambient_scan: {8_000, 600}`) — add a `:recipe_web_search` feature key alongside.

## Files the plan will touch (anticipated)

- `lib/tore/harness/artifact/recipe_proposal.ex` (new) + register in `artifact/registry.ex`
- `lib/tore/harness/verifier/recipe_proposal_verifier.ex` (new)
- `lib/tore/llm/planner_tools.ex` (add 2 read tools)
- `lib/tore/llm/planner_agent.ex` (recognize `{:proposal, ...}` → stop loop)
- `lib/tore/harness/orchestrator.ex` (needs_user carrying pending slot assignment; commit saves recipe + assigns)
- `lib/tore/llm/prompts.ex` (web-search op + recipe-generation op; English + locale param)
- `lib/tore/llm/openai.ex` and/or `Tore.LLM` facade (web plugin in body)
- `lib/tore/spend_guard.ex` (`:recipe_web_search` feature)
- `lib/tore/capture/router.ex` + `dispatch.ex` (optional: expose from Capture too)
- Tests per the design's Testing section.
- `SPEC.md` amendments (design doc lists them under "SPEC.md amendments").

## Project constraints to carry into the plan

- Push to master by default (workspace/PR only on explicit request).
- LLM prompts English; thread household locale as a parameter.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` (per prior session convention).
- If subagent-driven: subagents never run git/jj (controller-only VCS).
- SQLite parallel-load "Database busy" is a known pre-existing flake, not a regression.

## Task tracker state

Brainstorming tasks #25–#30 done. #31 (transition to writing-plans) is the resume point.
