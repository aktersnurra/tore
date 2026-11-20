defmodule Tore.Agent do
  @moduledoc """
  Background jobs for a household: a task from `harness/tasks/` sent to pi (`Tore.Pi`) in a
  session of its own, waited for, and recorded as a job with pi's summary and what it cost. Tore
  has no loop of its own here; the task file and `harness/AGENTS.md` are the instructions, the
  MCP tools and their verifiers are the limits.

  A job is for a week when it has one, so a schedule can tell it has run (`ran?/3`). `details`
  follow the task's instructions, such as which recipe a `finish_recipe` job is for.
  """

  import Ecto.Query

  alias Tore.{Household, Pi, Repo, Scope, Streams}
  alias Tore.Agent.Job

  require Logger

  @tasks_dir Path.expand("../../harness/tasks", __DIR__)
  @task_paths Path.wildcard(Path.join(@tasks_dir, "*.md"))
  @tasks for path <- @task_paths, into: %{}, do: {Path.basename(path, ".md"), File.read!(path)}
  for path <- @task_paths, do: @external_resource(path)

  # A task file added or removed changes the list, which `@external_resource` doesn't see.
  def __mix_recompile__?, do: Path.wildcard(Path.join(@tasks_dir, "*.md")) != @task_paths

  @timeout :timer.minutes(15)

  @spec tasks() :: [String.t()]
  def tasks, do: Map.keys(@tasks)

  @doc "A task's instructions, as `harness/tasks/<task>.md` has them."
  @spec task(String.t()) :: String.t()
  def task(name), do: Map.fetch!(@tasks, name)

  @doc "Cron entry: runs `task` once this week in each household that may use pi."
  @spec run_weekly(String.t()) :: :ok
  def run_weekly(task) do
    week = Streams.monday(Tore.Clock.today())

    Household.each_scope(fn scope ->
      if Pi.check(scope) == :ok and not ran?(scope, task, week), do: run(scope, task, week)
    end)
  end

  @doc """
  Starts `task` for the household and returns at once; nobody waits for it. The job's row is
  written before this returns, so `ran?/3` and a second `start/3` see it at once. Tests run it in
  place (`config :tore, :agent_in_background, false`), since a task outliving its test loses the
  test's database connection.
  """
  @spec start(Scope.t(), String.t(), String.t() | nil) :: :ok
  def start(%Scope{} = scope, task, details \\ nil) when is_map_key(@tasks, task) do
    with :ok <- Pi.check(scope), {:ok, job} <- open(scope, task, nil, details) do
      if Application.get_env(:tore, :agent_in_background, true) do
        {:ok, _pid} =
          Task.Supervisor.start_child(Tore.TaskSupervisor, fn -> execute(scope, job) end)
      else
        execute(scope, job)
      end
    end

    :ok
  end

  @doc """
  Runs `task` for the household and waits for it, which takes from seconds to minutes. `week` is
  the Monday of the week the job is for, when it is for one.
  """
  @spec run(Scope.t(), String.t(), Date.t() | nil, String.t() | nil) ::
          {:ok, Job.t()} | {:error, atom()}
  def run(%Scope{} = scope, task, week \\ nil, details \\ nil) when is_map_key(@tasks, task) do
    with :ok <- Pi.check(scope), {:ok, job} <- open(scope, task, week, details) do
      {:ok, execute(scope, job)}
    end
  end

  # The same job already running (a recipe finished twice, a second home pick) isn't started
  # again.
  defp open(scope, task, week, details) do
    running =
      from(j in Job, where: j.task == ^task and j.status == :running)
      |> where_week(week)
      |> where_details(details)
      |> Repo.exists?(Scope.repo_opts(scope))

    if running do
      {:error, :already_running}
    else
      {:ok,
       Repo.insert!(%Job{
         household_id: scope.household_id,
         task: task,
         week: week,
         details: details,
         status: :running
       })}
    end
  end

  # A session of its own: a fresh conversation, counted as the task. Whatever ends it, the row
  # leaves :running.
  defp execute(scope, job) do
    prompt =
      ["Background job: #{job.task}.", Map.fetch!(@tasks, job.task), job.details]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    result =
      try do
        Pi.run(scope, "#{job.task}-#{job.id}", prompt, timeout: @timeout)
      rescue
        error -> {:error, Exception.message(error)}
      catch
        kind, reason -> {:error, inspect({kind, reason})}
      end

    finish(job, result)
  end

  @doc """
  At boot every `running` job is dead, since a job lives in the process that started it. Marks
  them failed in every household, so `ran?/3` lets a schedule start them again.
  """
  @spec fail_interrupted() :: :ok
  def fail_interrupted do
    at = DateTime.utc_now(:second)

    Enum.each(Household.list_ids(), fn household_id ->
      Repo.update_all(
        from(j in Job, where: j.status == :running),
        [set: [status: :failed, summary: "interrupted", finished_at: at]],
        household_id: household_id
      )
    end)
  end

  @doc """
  Whether `task` has run for the week, or is running. A failed job doesn't count; one that timed
  out does, since running it again would likely spend as much again.
  """
  @spec ran?(Scope.t(), String.t(), Date.t() | nil) :: boolean()
  def ran?(%Scope{} = scope, task, week) do
    from(j in Job, where: j.task == ^task and j.status != :failed)
    |> where_week(week)
    |> Repo.exists?(Scope.repo_opts(scope))
  end

  defp where_week(query, nil), do: where(query, [j], is_nil(j.week))
  defp where_week(query, week), do: where(query, [j], j.week == ^week)

  defp where_details(query, nil), do: where(query, [j], is_nil(j.details))
  defp where_details(query, details), do: where(query, [j], j.details == ^details)

  # What the job cost is already in llm_usage, recorded by its pi session.
  defp finish(job, result) do
    changes =
      case result do
        {:ok, %{text: text, cost_usd: cost}} ->
          %{status: :succeeded, summary: text, cost_usd: cost}

        {:error, :timeout} ->
          %{status: :timed_out}

        {:error, reason} ->
          %{status: :failed, summary: "pi: #{reason}"}
      end

    job =
      job
      |> Ecto.Changeset.change(Map.put(changes, :finished_at, DateTime.utc_now(:second)))
      |> Repo.update!()

    Logger.info(
      "agent_job id=#{job.id} household=#{job.household_id} task=#{job.task} " <>
        "status=#{job.status} cost_usd=#{job.cost_usd}"
    )

    job
  end
end
