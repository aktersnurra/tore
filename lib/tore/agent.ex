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
  @tasks for path <- Path.wildcard(Path.join(@tasks_dir, "*.md")),
             into: %{},
             do: {Path.basename(path, ".md"), File.read!(path)}
  for path <- Path.wildcard(Path.join(@tasks_dir, "*.md")), do: @external_resource(path)

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
  Starts `task` for the household and returns at once; nobody waits for it. Tests run it in
  place (`config :tore, :agent_in_background, false`), since a task outliving its test loses the
  test's database connection.
  """
  @spec start(Scope.t(), String.t(), String.t() | nil) :: :ok
  def start(%Scope{} = scope, task, details \\ nil) when is_map_key(@tasks, task) do
    if Application.get_env(:tore, :agent_in_background, true) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Tore.TaskSupervisor, fn -> run(scope, task, nil, details) end)
    else
      run(scope, task, nil, details)
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
    with :ok <- Pi.check(scope) do
      job =
        Repo.insert!(%Job{
          household_id: scope.household_id,
          task: task,
          week: week,
          status: :running
        })

      # Recipes nothing prices get a guess first, so the week's estimate pi plans against
      # (get_context) counts them.
      if task == "plan_week", do: Tore.Prices.Estimate.missing(scope)

      prompt =
        ["Background job: #{task}.", Map.fetch!(@tasks, task), details]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      # A session of its own: a fresh conversation, counted as the task.
      {:ok, finish(job, Pi.run(scope, "#{task}-#{job.id}", prompt, timeout: @timeout))}
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
