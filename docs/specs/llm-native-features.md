# Design Notes — LLM-Native UX

Captured from design exploration session before updating SPEC.md.

---

## The Core Philosophy

**The system should have a good guess and make it easy to say yes or make a small correction.**

The LLM does the work. The user approves, ignores, or nudges. The app should work well when ignored — nothing cascades into brokenness because you skipped a week.

**The system should be more wrong about your kitchen and more right about your life.**

It won't have perfect pantry data. It won't have meal ratings. But it knows you skip Thursdays, that your batch cooks work better when the base is a sauce, and that ICA has a deal on pork this week. That's more useful than a precise pantry count.

---

## Where the "Perfect User" Assumption Hides

These are traps to avoid:

- **Pantry tracking** — drifts within two weeks. Once wrong, users stop trusting it, stop updating it, it gets more wrong. Every app with a pantry feature dies here.
- **Receipt scanning as required** — useful when it happens, invisible when it doesn't. Must degrade gracefully.
- **Meal ratings / feedback UI** — nobody rates their own home cooking. Feels absurd.
- **Plan as commitment** — if the UX implies you should follow the plan, deviation becomes mild guilt. The Duolingo problem.
- **Prep guide as checklist** — tapping the kiosk to report back with floury hands is not a UX, it's homework.
- **Nagging notifications** — "you haven't logged receipts in 14 days" is how apps get deleted.
- **Onboarding questionnaires** — infer preferences over time, don't front-load a survey.

---

## LLM-Native Features Worth Building

These are genuinely new, not just "an app that calls an LLM."

### 1. Longitudinal Learning — Passive, No Rating UI
The system synthesizes planning insights from existing events:
- `MealSkipped` events → infer patterns ("skips Thursdays 7/10 weeks")
- Recipes suggested but always swapped → infer dislikes
- Cascade plans that fail mid-week → infer that protein-based cascades don't stick

Stored as natural-language observations, injected into every plan prompt. Weekly Quantum job, no user interaction required. No rating UI, ever.

```
"Skips Thursday dinner most weeks — likely eats out. Fish on weekdays gets
 skipped 4x more than weekends. Batch cooks with chicken succeed but cascade
 rarely survives past Tuesday."
```

### 2. Natural Language Commands on the Planner
The planning decider already has the right commands. The LLM should be a UI layer over them:

> "Move salmon to Friday, too tired for fish on Tuesday" → LLM parses → issues `AssignRecipe` + `SwapRecipe` commands → events written.

NL is optional — buttons still work. But NL is the power path for lazy moments. This is what no existing meal planner does.

### 3. Proactive Intelligence — Surfaces, Never Interrupts
A cheap daily Quantum scan (not full plan generation) notices:
- Pantry item expiring + matching recipe not used recently → surfaces suggestion
- Cascade plan depends on Sunday prep but Sunday is empty → flags inconsistency before Monday
- Week unplanned by Wednesday → gentle draft based on current pantry + deals

Rule: the system *surfaces* suggestions in the UI, never *pushes* notifications about it.

### 4. Pantry as Inference, Not Management
- No pantry management UI as a primary feature
- Checked-off grocery items → implicitly in pantry
- Parsed receipts → auto-add line items to pantry
- LLM treats pantry state as **approximate** ("probably has olive oil, bought 3 weeks ago") not authoritative
- Lightweight correction UI, but zero expectation of maintenance

### 5. Receipt → Pantry Closed Loop
Already parsing receipts for cost tracking. Extend: after OCR, also call `Pantry.add_item` per line item. Zero extra user work. One action, two outcomes.

### 6. Fridge Photo → "What Can I Make Right Now?"
Camera → LLM identifies ingredients → instant suggestions from catalog. Useful for unplanned meals and weeks where the plan went sideways. Optional, not in the main flow.

---

## UX Principles

- **Skipping is first-class and neutral.** One tap, no confirmation, no "why?", no cascade warnings. Just noted.
- **The grocery list is the reliability anchor.** Works even if everything else is chaos. No plan? Add manually. Didn't sync pantry? Doesn't matter.
- **The kiosk has one job.** Tonight's dinner + what components are already prepped. Glanceable in 2 seconds with dirty hands. Week calendar is secondary.
- **No nagging.** The app is not allowed to nag. It is ready when you come to it.
- **Trust the user's choices.** Override the LLM suggestion without the app asking why.
- **The plan is a proposal, not a contract.** The app is comfortable with imperfection.

---

## Changes Needed in SPEC.md

- [ ] Demote `pantry_live.ex` — read-only "here's what we think you have" + lightweight correction, not full CRUD management
- [ ] Remove any implied rating/feedback UI
- [ ] Add `UserInsights` CRUD context — NL observations synthesized from events, weekly Quantum job
- [ ] Add `parse_planner_command/2` LLM callback — maps freetext to decider command structs
- [ ] Add ambient scan Quantum job — cheap daily, not full plan generation
- [ ] Extend `CostsHandler.parse_and_log_receipt` to also update pantry
- [ ] Add fridge photo → suggestions flow (Phase 8 or later)
- [ ] Cost analytics (`cost_live.ex`) out of main nav — occasional view, not weekly
- [ ] Clarify prep guide is a document you read, not a checklist you report back to
