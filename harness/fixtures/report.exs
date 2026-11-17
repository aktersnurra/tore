# What a household's week and memory look like now, the same for either arm of a comparison:
#
#     TORE_DEV_DB=/path/to/copy.db mix run harness/fixtures/report.exs [sub]

sub = List.first(System.argv()) || "harness-berg"
user = Tore.Repo.get_by!(Tore.Accounts.User, oidc_sub: sub)
{_user, scope} = Tore.Accounts.get_session(user.id)
{:ok, context} = Tore.Mcp.Tools.GetContext.call(scope, %{})

IO.puts("NEXT WEEK")

for slot <- context.next_week,
    do: IO.puts("  #{slot.date} #{slot.status} #{Map.get(slot, :recipe_title) || ""}")

IO.puts("\nMEMORY\n#{context.memory || "(empty)"}")
IO.puts("\nLLM SPEND THIS MONTH (server's model): $#{Tore.Costs.llm_spend_this_month(scope)}")
