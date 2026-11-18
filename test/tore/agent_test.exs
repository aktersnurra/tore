defmodule Tore.AgentTest do
  use Tore.DataCase, async: false

  alias Tore.{Agent, Costs}
  alias Tore.Agent.Job
  alias Tore.Mcp.SessionToken

  @runner Path.expand("../support/bin/fake-harness-run", __DIR__)

  setup do
    job_file = Path.join(System.tmp_dir!(), "agent-test-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:tore, :agent)

    Application.put_env(:tore, :agent,
      command: [@runner],
      mcp_url: "http://tore.test/mcp",
      model: "claude-sonnet-5-5",
      timeout_s: 600,
      max_budget_usd: 1.0
    )

    System.put_env("FAKE_AGENT_JOB", job_file)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tore, :agent, previous),
        else: Application.delete_env(:tore, :agent)

      for var <- ~w(FAKE_AGENT_JOB FAKE_AGENT_RESULT FAKE_AGENT_EXIT), do: System.delete_env(var)
      File.rm(job_file)
    end)

    %{job_file: job_file}
  end

  defp result(map), do: System.put_env("FAKE_AGENT_RESULT", Jason.encode!(map))

  test "a job runs the task for its household and records the summary and cost", %{
    job_file: job_file
  } do
    scope = home_scope()
    week = ~D[2026-11-23]

    result(%{
      status: "succeeded",
      summary: "Planned Mon–Sun, list made.",
      cost_usd: 0.05,
      tokens: %{input: 1200, output: 300}
    })

    assert {:ok, %Job{} = job} = Agent.run(scope, "plan_week", week)

    assert %Job{status: :succeeded, summary: "Planned Mon–Sun, list made.", cost_usd: 0.05} = job
    assert job.week == week and job.finished_at

    sent = job_file |> File.read!() |> Jason.decode!()

    assert %{
             "job" => job_id,
             "household" => household_id,
             "task" => "plan_week",
             "mcp_url" => "http://tore.test/mcp",
             "model" => "claude-sonnet-5-5",
             "timeout_s" => 600,
             "max_budget_usd" => 1.0,
             "token" => token
           } = sent

    assert job_id == to_string(job.id) and household_id == scope.household_id
    # The token signs in as this household only.
    assert {:ok, %Tore.Scope{household_id: ^household_id, user_id: nil}} =
             SessionToken.verify(token)

    assert [{"agent_plan_week", 1, 0.05}] = Costs.llm_calls_this_month_by_feature(scope)
    assert Agent.ran?(scope, "plan_week", week)
    refute Agent.ran?(scope, "plan_week", Date.add(week, 7))
  end

  test "a runner that fails, or answers nonsense, fails the job and it can run again" do
    scope = home_scope()

    System.put_env("FAKE_AGENT_EXIT", "3")
    assert {:ok, %Job{status: :failed, summary: summary}} = Agent.run(scope, "weekly_reflection")
    assert summary =~ "exit 3"

    System.delete_env("FAKE_AGENT_EXIT")
    System.put_env("FAKE_AGENT_RESULT", "not json")
    assert {:ok, %Job{status: :failed}} = Agent.run(scope, "weekly_reflection")

    refute Agent.ran?(scope, "weekly_reflection", nil)
  end

  test "a timed-out job is recorded as such, with what it cost" do
    result(%{status: "timed_out", summary: nil, cost_usd: 0.4})

    assert {:ok, %Job{status: :timed_out, cost_usd: 0.4}} = Agent.run(home_scope(), "plan_week")
  end

  test "no job without a sponsor, over the monthly limit, or with no runner configured" do
    unsponsored = scope_fixture(household_fixture())
    assert {:error, :ai_unavailable} = Agent.run(unsponsored, "plan_week")

    {:ok, _} =
      Costs.log_llm_usage(home_scope(), %{
        feature: "other",
        cost_usd: Tore.LLM.monthly_limit_usd()
      })

    assert {:error, :budget_exceeded} = Agent.run(home_scope(), "plan_week")

    Application.delete_env(:tore, :agent)
    assert {:error, :agent_off} = Agent.run(unsponsored, "plan_week")

    for scope <- [unsponsored, home_scope()],
        do: assert(Repo.all(Job, Tore.Scope.repo_opts(scope)) == [])
  end
end
