#!/bin/sh
# Runs one task from harness/tasks against a Tore's /mcp with Claude Code, headless, and prints
# Claude Code's final result line. The whole stream goes to the transcript, if one is named.
#
#   ANTHROPIC_API_KEY=… TORE_MCP_URL=http://localhost:4100/mcp TORE_MCP_TOKEN=… \
#     harness/run-local.sh plan_week [transcript.jsonl]
#
# Takes ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN (a subscription token from
# `claude setup-token`).
#
# The developer's own CLAUDE.md files, settings, hooks, plugins and memory stay out of the
# household agent: it gets an empty config dir and works in a copy of harness/ outside the
# repository, where there is no CLAUDE.md to find. Its instructions are AGENTS.md and the task.
# Not --bare: that mode has no web tools and still loads the developer's plugins.
set -eu

task=${1:?usage: run-local.sh <task> [transcript.jsonl]}
transcript=${2:-/dev/null}
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

[ -f "$dir/tasks/$task.md" ] || { echo "run-local: no task $dir/tasks/$task.md" >&2; exit 1; }
[ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] ||
  { echo "run-local: set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN" >&2; exit 1; }
: "${TORE_MCP_URL:?set TORE_MCP_URL}"
: "${TORE_MCP_TOKEN:?set TORE_MCP_TOKEN}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The token goes in a file only this user can read, not on the command line.
config="$work/mcp.json"
(umask 077 && printf '{"mcpServers":{"tore":{"type":"http","url":"%s","headers":{"Authorization":"Bearer %s"}}}}\n' \
  "$TORE_MCP_URL" "$TORE_MCP_TOKEN" >"$config")

mkdir "$work/config" "$work/harness"
cp -R "$dir/AGENTS.md" "$dir/tasks" "$work/harness/"
export CLAUDE_CONFIG_DIR="$work/config"
cd "$work/harness"

claude -p "$(cat "tasks/$task.md")" \
  --append-system-prompt-file AGENTS.md \
  --mcp-config "$config" --strict-mcp-config \
  --tools WebSearch,WebFetch \
  --allowedTools mcp__tore WebSearch WebFetch \
  ${CLAUDE_MODEL:+--model "$CLAUDE_MODEL"} \
  --max-budget-usd "${MAX_BUDGET_USD:-2}" \
  --no-session-persistence \
  --output-format stream-json --verbose |
  tee "$transcript" | tail -n 1
