defmodule Tore.AgentTest do
  use Tore.DataCase, async: false

  alias Tore.{Agent, Costs}
  alias Tore.Agent.Job

  import Tore.FakePi

  setup :fake_pi

  test "a job sends the task to pi in a session of its own and records what came back", %{
    pi_log: log
  } do
    System.put_env("FAKE_PI_REPLY", "Planned Mon–Sun, list made.")
    System.put_env("FAKE_PI_COST", "0.05")
    scope = home_scope()
    week = ~D[2026-11-23]

    assert {:ok, %Job{status: :succeeded, summary: "Planned Mon–Sun, list made."} = job} =
             Agent.run(scope, "plan_week", week)

    assert job.cost_usd == 0.05 and job.week == week and job.finished_at

    [header, prompt] = log |> File.read!() |> String.split("\n", trim: true)
    assert Jason.decode!(header)["session"] == "plan_week"

    assert Jason.decode!(prompt)["message"] =~
             ~r/\ABackground job: plan_week\.\n\n# Plan next week/

    assert [{"pi_plan_week", 1, 0.05}] = Costs.llm_calls_this_month_by_feature(scope)
    assert Agent.ran?(scope, "plan_week", week)
    refute Agent.ran?(scope, "plan_week", Date.add(week, 7))
  end

  test "a pi that dies fails the job, and a failed job can run again" do
    Application.put_env(:tore, :pi, command: ["false"])

    assert {:ok, %Job{status: :failed, summary: "pi: exited"}} =
             Agent.run(home_scope(), "weekly_reflection")

    refute Agent.ran?(home_scope(), "weekly_reflection", nil)
  end

  test "no job for a household that may not use pi" do
    unsponsored = scope_fixture(household_fixture())
    assert {:error, :ai_unavailable} = Agent.run(unsponsored, "plan_week")
    assert Repo.all(Job, Tore.Scope.repo_opts(unsponsored)) == []
  end

  test "the weekly cron runs once a week, in each household that may use pi" do
    unsponsored = scope_fixture(household_fixture())
    over_limit = scope_fixture(household_fixture())

    sponsor =
      user_fixture(household: Repo.get!(Tore.Household.HouseholdSchema, over_limit.household_id))

    Repo.update_all(from(u in Tore.Accounts.User, where: u.id == ^sponsor.id),
      set: [ai_enabled: true]
    )

    Repo.update_all(
      from(h in Tore.Household.HouseholdSchema, where: h.id == ^over_limit.household_id),
      set: [ai_sponsor_id: sponsor.id]
    )

    {:ok, _} =
      Costs.log_llm_usage(over_limit, %{feature: "seed", cost_usd: Tore.LLM.monthly_limit_usd()})

    assert :ok = Agent.run_weekly("weekly_reflection")
    assert :ok = Agent.run_weekly("weekly_reflection")

    jobs = fn scope -> Repo.all(Job, Tore.Scope.repo_opts(scope)) end
    assert [%Job{task: "weekly_reflection", status: :succeeded}] = jobs.(home_scope())
    assert jobs.(unsponsored) == [] and jobs.(over_limit) == []
  end
end
