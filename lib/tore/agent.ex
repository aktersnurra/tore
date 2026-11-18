defmodule Tore.Agent do
  @moduledoc """
  Runs a task from `harness/tasks/` for one household on the harness: Claude Code (or opencode)
  on the harness guest, reaching Tore only through `/mcp` with a session token for that
  household (`Tore.Mcp.SessionToken`). Tore has no loop of its own here; the task file and
  `harness/AGENTS.md` are the instructions, the MCP tools and their verifiers are the limits.

  The runner is a command (`config :tore, :agent, command: [...]`): `harness/harness-run` on
  this machine, or ssh to the guest, where a forced command runs it. It reads one job as JSON on
  stdin and prints one result as JSON. Without a command configured, no job runs.

  A job needs what a call to the server's model needs: someone sponsoring the household and
  room under its monthly limit. What the job cost is recorded in `llm_usage` as
  `agent_<task>`, so the limit sees it.
  """

  import Ecto.Query

  alias Tore.{Costs, Household, Repo, Scope}
  alias Tore.Agent.Job
  alias Tore.Mcp.SessionToken

  require Logger

  @tasks ~w(plan_week weekly_reflection find_recipes)
  # How long past its own time limit a job's token stays good.
  @token_margin_s 120

  @spec configured?() :: boolean()
  def configured?, do: config()[:command] not in [nil, []]

  @doc "Whether a job may run for this household now: `:ok`, or why not."
  @spec check(Scope.t()) :: :ok | {:error, :agent_off | :ai_unavailable | :budget_exceeded}
  def check(%Scope{} = scope) do
    cond do
      not configured?() ->
        {:error, :agent_off}

      Household.ai_sponsor(scope) == nil ->
        {:error, :ai_unavailable}

      Costs.llm_spend_this_month(scope) >= Tore.LLM.monthly_limit_usd() ->
        {:error, :budget_exceeded}

      true ->
        :ok
    end
  end

  @doc """
  Runs `task` for the household and waits for it, which takes from seconds to minutes. `week` is
  the Monday of the week the job is for, when it is for one, so a schedule can tell it has run.
  """
  @spec run(Scope.t(), String.t(), Date.t() | nil) :: {:ok, Job.t()} | {:error, atom()}
  def run(%Scope{} = scope, task, week \\ nil) when task in @tasks do
    with :ok <- check(scope) do
      job =
        Repo.insert!(%Job{
          household_id: scope.household_id,
          task: task,
          week: week,
          status: :running
        })

      {:ok, finish(scope, job, dispatch(job))}
    end
  end

  @doc "Whether `task` has run for the week, or is running. A failed job doesn't count."
  @spec ran?(Scope.t(), String.t(), Date.t() | nil) :: boolean()
  def ran?(%Scope{} = scope, task, week) do
    from(j in Job, where: j.task == ^task and j.status != :failed)
    |> where_week(week)
    |> Repo.exists?(Scope.repo_opts(scope))
  end

  defp where_week(query, nil), do: where(query, [j], is_nil(j.week))
  defp where_week(query, week), do: where(query, [j], j.week == ^week)

  defp dispatch(job) do
    config = config()
    timeout_s = Keyword.get(config, :timeout_s, 900)

    request = %{
      job: to_string(job.id),
      household: job.household_id,
      task: job.task,
      mcp_url: config[:mcp_url] || ToreWeb.Endpoint.url() <> "/mcp",
      token: SessionToken.mint(job.household_id, to_string(job.id), timeout_s + @token_margin_s),
      model: config[:model],
      timeout_s: timeout_s,
      max_budget_usd: Keyword.get(config, :max_budget_usd, 1.0)
    }

    # The job holds a token, so it goes through a file only this user can read, not argv.
    path = Path.join(System.tmp_dir!(), "tore-agent-job-#{job.id}-#{System.unique_integer()}")
    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, Jason.encode!(request))

    try do
      System.cmd("sh", ["-c", ~s(exec "$@" < "$TORE_AGENT_JOB"), "sh" | config[:command]],
        env: [{"TORE_AGENT_JOB", path}]
      )
    after
      File.rm(path)
    end
    |> decode()
  end

  defp decode({out, 0}) do
    case Jason.decode(out) do
      {:ok, %{"status" => status} = result} when status in ~w(succeeded failed timed_out) ->
        {:ok, result}

      _ ->
        {:error, "unreadable result: #{tail(out)}"}
    end
  end

  defp decode({out, code}), do: {:error, "exit #{code}: #{tail(out)}"}

  defp tail(out), do: out |> String.trim() |> String.slice(-500, 500)

  defp finish(scope, job, result) do
    changes =
      case result do
        {:ok, r} ->
          %{
            status: String.to_existing_atom(r["status"]),
            summary: r["summary"],
            cost_usd: (r["cost_usd"] || 0) / 1
          }

        {:error, reason} ->
          %{status: :failed, summary: reason, cost_usd: 0.0}
      end

    job =
      job
      |> Ecto.Changeset.change(Map.put(changes, :finished_at, DateTime.utc_now(:second)))
      |> Repo.update!()

    if job.cost_usd > 0 do
      tokens = (match?({:ok, _}, result) && elem(result, 1)["tokens"]) || %{}

      {:ok, _} =
        Costs.log_llm_usage(scope, %{
          feature: "agent_#{job.task}",
          prompt_tokens: tokens["input"] || 0,
          completion_tokens: tokens["output"] || 0,
          cost_usd: job.cost_usd
        })
    end

    Logger.info(
      "agent_job id=#{job.id} household=#{job.household_id} task=#{job.task} " <>
        "status=#{job.status} cost_usd=#{job.cost_usd}"
    )

    job
  end

  defp config, do: Application.get_env(:tore, :agent, [])
end
