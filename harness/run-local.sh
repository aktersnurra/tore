#!/bin/sh
# Runs one task from harness/tasks against a Tore's /mcp with Claude Code, headless, and prints
# Claude Code's final result line. The whole stream goes to the transcript, if one is named.
#
#   ANTHROPIC_API_KEY=… TORE_MCP_URL=http://localhost:4100/mcp TORE_MCP_TOKEN=… \
#     harness/run-local.sh plan_week [transcript.jsonl]
#
# --bare keeps the developer's own CLAUDE.md files, settings, hooks and plugins out of the
# household agent; its instructions are harness/AGENTS.md and the task. It needs an API key.
set -eu

task=${1:?usage: run-local.sh <task> [transcript.jsonl]}
transcript=${2:-/dev/null}
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

[ -f "$dir/tasks/$task.md" ] || { echo "run-local: no task $dir/tasks/$task.md" >&2; exit 1; }
: "${ANTHROPIC_API_KEY:?set ANTHROPIC_API_KEY}"
: "${TORE_MCP_URL:?set TORE_MCP_URL}"
: "${TORE_MCP_TOKEN:?set TORE_MCP_TOKEN}"

# The token goes in a file only this user can read, not on the command line.
config=$(mktemp)
trap 'rm -f "$config"' EXIT
chmod 600 "$config"
printf '{"mcpServers":{"tore":{"type":"http","url":"%s","headers":{"Authorization":"Bearer %s"}}}}\n' \
  "$TORE_MCP_URL" "$TORE_MCP_TOKEN" >"$config"

cd "$dir"
claude --bare -p "$(cat "tasks/$task.md")" \
  --append-system-prompt-file AGENTS.md \
  --mcp-config "$config" --strict-mcp-config \
  --tools WebSearch,WebFetch \
  --allowedTools mcp__tore WebSearch WebFetch \
  ${CLAUDE_MODEL:+--model "$CLAUDE_MODEL"} \
  --max-budget-usd "${MAX_BUDGET_USD:-2}" \
  --no-session-persistence \
  --output-format stream-json --verbose |
  tee "$transcript" | tail -n 1
