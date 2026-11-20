## Phase Implementation Workflow
- When asked to implement a phase from SPEC.md, first output a concise plan with checkpoints
- Break implementation into discrete commits per checkpoint (migrations, deps, context, features)
- After each checkpoint, summarize what was done and what's next so work can resume cleanly across sessions

## Project Context
- This project uses a SPEC.md as the source of truth for phased implementation
- Always read SPEC.md before planning or implementing new phases
- Skills/commands live under .claude/skills/ — reference them in docs and READMEs
- Schema changes get a new, additive migration (`mix ecto.gen.migration`); never edit one that exists, so a dev database is migrated, not reset

## Docs
- `SPEC.md` at the root is the source of truth. `docs/specs/ui.md` and `docs/specs/llm-native-features.md` go with it.
