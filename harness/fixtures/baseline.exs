# The arm the harness is compared with: Tore's own weekly planning and memory review runs, on
# the server's model. Needs the server's OpenRouter key in the environment.
#
#     TORE_DEV_DB=/path/to/copy.db mix run harness/fixtures/baseline.exs [sub]

alias Tore.Harness.{Kinds, Runs}

sub = List.first(System.argv()) || "harness-berg"
user = Tore.Repo.get_by!(Tore.Accounts.User, oidc_sub: sub)
{_user, scope} = Tore.Accounts.get_session(user.id)

for {name, start} <- [
      planning: fn -> Tore.Planning.plan_upcoming_week(scope) end,
      memory_review: fn -> Runs.start(scope, Kinds.MemoryReview, %{}) end
    ] do
  {micros, result} = :timer.tc(start)

  outcome =
    case result do
      {:ok, run} -> "#{run.status} (#{run.id})"
      {:error, reason} -> "error #{inspect(reason)}"
    end

  IO.puts("#{name}: #{outcome} in #{div(micros, 1_000_000)} s")
end
