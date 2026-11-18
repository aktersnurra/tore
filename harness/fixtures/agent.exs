# Runs one harness task for a household against this machine's Tore, the way the schedule does,
# and prints the job. A server must be running on the same database for the harness to reach:
#
#     TORE_DEV_DB=/path/to/copy.db PORT=4100 mix phx.server
#     ANTHROPIC_API_KEY=… TORE_DEV_DB=/path/to/copy.db TORE_AGENT_COMMAND=harness/harness-run \
#       TORE_AGENT_MCP_URL=http://localhost:4100/mcp mix run harness/fixtures/agent.exs plan_week
#
# The second argument is the member's sub (default harness-berg, from berg.exs).

[task | rest] = System.argv()
sub = List.first(rest) || "harness-berg"
user = Tore.Repo.get_by!(Tore.Accounts.User, oidc_sub: sub)
{_user, scope} = Tore.Accounts.get_session(user.id)

{micros, result} = :timer.tc(fn -> Tore.Agent.run(scope, task) end)

case result do
  {:ok, job} ->
    IO.puts("#{task}: #{job.status} in #{div(micros, 1_000_000)} s, $#{job.cost_usd}")
    IO.puts(job.summary || "")

  {:error, reason} ->
    IO.puts("#{task}: not run, #{reason}")
end
