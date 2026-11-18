defmodule Tore.Agent.HarnessRunTest do
  # harness/harness-run itself, with a stub Claude Code on the PATH, and Tore.Agent driving it.
  use Tore.DataCase, async: false

  alias Tore.Agent

  @run Path.expand("../../../harness/harness-run", __DIR__)
  @stub_dir Path.expand("../../support/stub_claude", __DIR__)

  @success ~s({"type":"result","subtype":"success","result":"Planned the week.","total_cost_usd":0.05,) <>
             ~s("usage":{"input_tokens":10,"cache_read_input_tokens":900,"cache_creation_input_tokens":90,"output_tokens":40}})

  setup do
    tmp = Path.join(System.tmp_dir!(), "harness-run-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    env = %{
      "PATH" => @stub_dir <> ":" <> System.get_env("PATH"),
      "HARNESS_STATE_DIR" => Path.join(tmp, "state"),
      "ANTHROPIC_API_KEY" => "test-key",
      "STUB_CLAUDE_OUT" => Path.join(tmp, "claude.txt"),
      "STUB_CLAUDE_RESULT" => @success
    }

    %{tmp: tmp, env: env}
  end

  defp job(overrides \\ %{}) do
    Map.merge(
      %{
        job: "7",
        household: 3,
        task: "plan_week",
        mcp_url: "http://tore.test/mcp",
        token: "session-token",
        model: "claude-sonnet-5-5",
        timeout_s: 30,
        max_budget_usd: 1.0
      },
      overrides
    )
  end

  defp run(env, job) do
    file = Path.join(env["HARNESS_STATE_DIR"] <> "-in", "job.json")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Jason.encode!(job))

    {out, 0} =
      System.cmd("sh", ["-c", ~s(exec "$0" < "$1"), @run, file], env: Map.to_list(env))

    Jason.decode!(out)
  end

  test "runs the task in a clean directory with Tore as its only MCP server", %{env: env} do
    assert %{
             "status" => "succeeded",
             "summary" => "Planned the week.",
             "cost_usd" => 0.05,
             "tokens" => %{"input" => 1000, "output" => 40},
             "transcript" => transcript
           } = run(env, job())

    assert File.read!(transcript) =~ ~s("subtype":"success")

    started = File.read!(env["STUB_CLAUDE_OUT"])
    # Nowhere near the repository, so no CLAUDE.md of the developer's is found.
    refute started =~ "cwd=#{File.cwd!()}"
    assert started =~ ~r/config=\S+/
    assert started =~ "--model claude-sonnet-5-5"
    assert started =~ "--strict-mcp-config"
    assert started =~ "# Plan next week"
    assert started =~ ~s("Authorization":"Bearer session-token")
    assert started =~ ~s("url":"http://tore.test/mcp")
    # The token reaches Claude Code in a file, never on its command line.
    [args] = Regex.run(~r/^args=.*$/m, started)
    refute args =~ "session-token"
  end

  test "a job it can't run is a failed result saying why", %{env: env} do
    assert %{"status" => "failed", "summary" => "no task make_cake"} =
             run(env, job(%{task: "make_cake"}))

    assert %{"status" => "failed", "summary" => "bad household"} =
             run(env, job(%{household: "3; rm -rf /"}))

    assert %{"status" => "failed", "summary" => "no ANTHROPIC_API_KEY" <> _} =
             run(Map.delete(env, "ANTHROPIC_API_KEY"), job())
  end

  test "Claude Code that stops short, or runs out of time", %{env: env} do
    budget = ~s({"type":"result","subtype":"error_max_budget_usd","total_cost_usd":1.01})

    assert %{"status" => "failed", "summary" => "error_max_budget_usd", "cost_usd" => 1.01} =
             run(%{env | "STUB_CLAUDE_RESULT" => budget}, job())

    assert %{"status" => "timed_out"} =
             run(Map.put(env, "STUB_CLAUDE_SLEEP", "5"), job(%{timeout_s: 1}))
  end

  test "Tore.Agent runs a job through it", %{env: env} do
    previous = Application.get_env(:tore, :agent)
    on_exit(fn -> Application.put_env(:tore, :agent, previous || []) end)

    for {k, v} <- env, do: System.put_env(k, v)
    on_exit(fn -> for {k, _} <- env, k != "PATH", do: System.delete_env(k) end)

    on_exit(fn ->
      System.put_env("PATH", String.replace_prefix(env["PATH"], @stub_dir <> ":", ""))
    end)

    Application.put_env(:tore, :agent, command: [@run], timeout_s: 30)

    assert {:ok, %Agent.Job{status: :succeeded, summary: "Planned the week.", cost_usd: 0.05}} =
             Agent.run(home_scope(), "plan_week")
  end
end
