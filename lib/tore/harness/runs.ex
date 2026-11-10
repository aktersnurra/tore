defmodule Tore.Harness.Runs do
  @moduledoc """
  Runs a kind through its steps and keeps the `runs` row in step with it.

      start ─ propose ─ resolve ─ verify ─┬─ apply ──────────────→ applied ─ revert → reverted
                 │                        ├─ review → needs_user ─ confirm → applied
                 └─ ask ──────────────────┼────────→ needs_user ─ discard → discarded
                                          └─ fail → failed

  Domain writes happen only in `apply_proposal`, in one transaction with the status change. Every
  row write is conditional on the status the caller read, so two changes racing (a confirm and
  the TTL sweep's discard, or two taps on Confirm) can't both win. After each commit
  `{:run_changed, run}` goes out on `runs:household:<id>`, then the kind's best-effort
  `after_commit/1` runs.

  A kind that fails its verifier ends `failed` and returns `{:ok, run}`. A step that errors ends
  `failed` too and returns `{:error, {:step_failed, reason}}`, so screens can say why through
  `Tore.LLM.refusal_text/1`; a crash, exit or throw returns `{:error, {:run_crashed, reason}}`.

  A run's token and cost columns count the usage `propose` returns with a proposal. A call that
  ends in a question or an error is in `llm_usage` only.
  """

  require Logger
  import Ecto.Query

  alias Tore.{Repo, Scope}
  alias Tore.Harness.{Kinds, KitchenRun}
  alias Tore.Harness.KitchenRun.Transition

  @type result ::
          {:ok, KitchenRun.t()} | {:error, {:step_failed, term()} | {:run_crashed, term()}}

  @refusals [:ai_unavailable, :budget_exceeded]

  @doc "Opens a run of `kind` and takes it as far as it goes without a person."
  @spec start(Scope.t(), module(), map()) :: result()
  def start(%Scope{} = scope, kind, ctx) do
    ctx = Map.put(ctx, :scope, scope)
    run = open!(scope, kind, ctx)

    guard(run, kind, fn ->
      run = phase!(run, :proposing)

      case kind.propose(run, ctx) do
        {:ok, proposal, usage} -> run |> add_usage!(usage) |> settle(kind, proposal, ctx)
        {:ask, question} -> finish!(run, kind, {:ask, question}, %{})
        {:error, reason} -> step_failed(run, kind, reason)
      end
    end)
  end

  @doc "Opens a run with a proposal already made, by Capture or over MCP. No LLM call."
  @spec submit(Scope.t(), module(), Tore.Harness.Kind.proposal(), map()) :: result()
  def submit(%Scope{} = scope, kind, proposal, ctx) do
    ctx = Map.put(ctx, :scope, scope)
    run = open!(scope, kind, ctx)
    guard(run, kind, fn -> settle(run, kind, proposal, ctx) end)
  end

  @doc """
  Applies a run waiting for review, with the proposal as the person left it. A proposal that
  fails its verifier leaves the run waiting, so they can correct it.
  """
  @spec confirm(Scope.t(), String.t(), Tore.Harness.Kind.proposal()) ::
          {:ok, KitchenRun.t()}
          | {:error,
             :not_found
             | {:invalid_transition, atom(), atom()}
             | {:status_changed, atom()}
             | {:verifier_failed, atom(), term()}
             | {:run_crashed, term()}
             | term()}
  def confirm(%Scope{} = scope, run_id, proposal) do
    with {:ok, run} <- fetch(scope, run_id),
         :ok <- waiting(run, :confirm) do
      kind = Kinds.fetch!(run.kind)
      ctx = %{scope: scope, run: run}

      try do
        with {:ok, proposal} <- resolve(kind, proposal, ctx),
             :ok <- verified(kind.verify(proposal, ctx)) do
          commit_apply(run, kind, proposal, ctx, :confirm)
        end
      catch
        class, reason -> {:error, {:run_crashed, logged(run, class, reason, __STACKTRACE__)}}
      end
    end
  end

  @spec discard(Scope.t(), String.t(), :user_discarded | :ttl_expired) ::
          {:ok, KitchenRun.t()} | {:error, term()}
  def discard(%Scope{} = scope, run_id, reason) do
    with {:ok, run} <- fetch(scope, run_id) do
      finish(run, Kinds.fetch!(run.kind), {:discard, reason}, %{})
    end
  end

  @doc """
  Restores what the run changed, in one transaction with the status change. A step that can't
  be undone raises, and the run stays applied.
  """
  @spec revert(Scope.t(), String.t()) :: {:ok, KitchenRun.t()} | {:error, term()}
  def revert(%Scope{} = scope, run_id) do
    with {:ok, run} <- fetch(scope, run_id),
         kind = Kinds.fetch!(run.kind),
         {:ok, changes} <- Transition.next(run, :revert, now()) do
      Repo.transaction(fn ->
        undo!(scope, run.undo)

        case move(run, changes) do
          {:ok, reverted} -> reverted
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, reverted} -> committed(reverted, kind)
        {:error, _} = error -> error
      end
    end
  end

  @spec get(Scope.t(), String.t()) :: KitchenRun.t() | nil
  def get(%Scope{} = scope, run_id), do: Repo.get(KitchenRun, run_id, Scope.repo_opts(scope))

  @doc "Runs waiting for someone, newest first."
  @spec list_pending(Scope.t()) :: [KitchenRun.t()]
  def list_pending(%Scope{} = scope) do
    from(r in KitchenRun, where: r.status == :needs_user, order_by: [desc: r.opened_at])
    |> Repo.all(Scope.repo_opts(scope))
  end

  @doc """
  Runs waiting with a proposal for someone to review, oldest first. A run waiting on a question
  has nothing to review, so it isn't one.
  """
  @spec list_reviews(Scope.t()) :: [KitchenRun.t()]
  def list_reviews(%Scope{} = scope),
    do: scope |> list_pending() |> Enum.reject(&(&1.artifacts == [])) |> Enum.reverse()

  @spec latest_on_surface(Scope.t(), atom()) :: KitchenRun.t() | nil
  def latest_on_surface(%Scope{} = scope, surface) do
    from(r in KitchenRun, where: r.surface == ^surface, order_by: [desc: r.opened_at], limit: 1)
    |> Repo.one(Scope.repo_opts(scope))
  end

  @doc """
  At boot every `running` row is dead, since runs live in the process that started them. Marks
  them failed with `:interrupted`, in every household.
  """
  @spec fail_interrupted() :: :ok
  def fail_interrupted do
    at = now()

    Enum.each(Tore.Household.list_ids(), fn household_id ->
      Repo.update_all(
        from(r in KitchenRun, where: r.status == :running),
        [set: [status: :failed, failure_code: :interrupted, closed_at: at, phase: nil]],
        household_id: household_id
      )
    end)
  end

  @doc false
  # A supervisor child that sweeps once, after migrations and before anything can open a run.
  def start_sweep do
    if Application.get_env(:tore, :fail_interrupted_runs_at_boot, true), do: fail_interrupted()
    :ignore
  end

  @doc false
  def child_spec(_arg), do: %{id: __MODULE__, start: {__MODULE__, :start_sweep, []}}

  @spec topic(Scope.t()) :: String.t()
  def topic(%Scope{household_id: household_id}), do: "runs:household:#{household_id}"

  # ----- the flow --------------------------------------------------------------------------

  defp settle(run, kind, proposal, ctx) do
    ctx = Map.put(ctx, :run, run)

    with {:ok, proposal} <- resolve(kind, proposal, ctx),
         run = phase!(run, :verifying),
         :ok <- kind.verify(proposal, Map.put(ctx, :run, run)) do
      case kind.review_question(proposal) do
        nil -> commit_apply(run, kind, proposal, ctx, :apply)
        question -> finish!(run, kind, {:review, question}, %{artifacts: List.wrap(proposal)})
      end
    else
      {:fail, code, repair} ->
        finish!(run, kind, {:fail, code, nil, repair}, %{artifacts: List.wrap(proposal)})

      {:error, reason} ->
        step_failed(run, kind, reason)
    end
  end

  defp resolve(kind, proposal, ctx) do
    if function_exported?(kind, :resolve, 2),
      do: kind.resolve(proposal, ctx),
      else: {:ok, proposal}
  end

  defp verified(:ok), do: :ok
  defp verified({:fail, code, repair}), do: {:error, {:verifier_failed, code, repair}}

  defp waiting(%KitchenRun{status: :needs_user}, _action), do: :ok

  defp waiting(%KitchenRun{status: status}, action),
    do: {:error, {:invalid_transition, status, action}}

  defp commit_apply(run, kind, proposal, ctx, action) do
    Repo.transaction(fn ->
      with {:ok, undo, artifacts} <- kind.apply_proposal(proposal, Map.put(ctx, :run, run)),
           {:ok, changes} <- Transition.next(run, {action, undo}, now()),
           {:ok, applied} <- move(run, Map.put(changes, :artifacts, artifacts)) do
        applied
      else
        {:fail, code, repair} -> Repo.rollback({:fail, code, repair})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, run} ->
        committed(run, kind)

      {:error, {:fail, code, repair}} when action == :apply ->
        finish!(run, kind, {:fail, code, nil, repair}, %{})

      {:error, {:fail, code, repair}} ->
        {:error, {:verifier_failed, code, repair}}

      {:error, reason} when action == :apply ->
        step_failed(run, kind, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(run, kind, action, extra) do
    with {:ok, changes} <- Transition.next(run, action, now()),
         {:ok, run} <- move(run, Map.merge(changes, extra)) do
      committed(run, kind)
    end
  end

  # Inside the flow a refused move is a bug in the kind (a blank question, say), so it fails the
  # run through `guard` rather than leaving it running.
  defp finish!(run, kind, action, extra) do
    {:ok, run} = finish(run, kind, action, extra)
    {:ok, run}
  end

  defp step_failed(run, kind, reason) do
    code = if reason in @refusals, do: reason, else: :internal_error
    Logger.warning("#{run.kind} #{run.id} failed: #{inspect(reason, limit: 20)}")
    {:ok, _failed} = finish(run, kind, {:fail, code, nil, nil}, %{})
    {:error, {:step_failed, reason}}
  end

  # A crash, exit or throw ends the run failed. The row is read again, because the crash may
  # have come after a status change the caller's copy doesn't show.
  defp guard(run, kind, fun) do
    fun.()
  catch
    class, reason ->
      reason = logged(run, class, reason, __STACKTRACE__)

      case get(Scope.for_household(run.household_id), run.id) do
        %KitchenRun{status: :running} = current ->
          finish(current, kind, {:fail, :internal_error, nil, nil}, %{})

        _ ->
          :ok
      end

      {:error, {:run_crashed, reason}}
  end

  defp logged(run, class, reason, stacktrace) do
    Logger.error("#{run.kind} #{run.id} crashed: " <> Exception.format(class, reason, stacktrace))
    if class == :error, do: Exception.normalize(:error, reason, stacktrace), else: reason
  end

  # The run has committed, so what follows can't change the result: the broadcast goes first,
  # and a failing `after_commit` is logged.
  defp committed(run, kind) do
    broadcast(run)

    if function_exported?(kind, :after_commit, 1) do
      try do
        kind.after_commit(run)
      catch
        class, reason ->
          Logger.error(
            "#{run.kind} #{run.id} after_commit failed: " <>
              Exception.format(class, reason, __STACKTRACE__)
          )
      end
    end

    {:ok, run}
  end

  # ----- rows --------------------------------------------------------------------------------

  defp open!(scope, kind, ctx) do
    # A kind missing from the registry couldn't be confirmed, discarded or reverted later.
    ^kind = Kinds.fetch!(kind.kind())
    %{input: input, actor: actor} = kind.open(ctx)

    run =
      scope
      |> KitchenRun.open(
        %{
          kind: kind.kind(),
          surface: kind.surface(),
          actor: actor,
          input: input,
          parent_id: ctx[:parent_id],
          phase: :gathering_context
        },
        now()
      )
      |> Repo.insert!()

    broadcast(run)
    run
  end

  defp phase!(run, phase) do
    {:ok, changes} = Transition.next(run, {:phase, phase}, now())
    {:ok, run} = move(run, changes)
    broadcast(run)
    run
  end

  defp add_usage!(run, usage) do
    {:ok, run} =
      move(run, %{
        prompt_tokens: run.prompt_tokens + (usage[:prompt_tokens] || 0),
        completion_tokens: run.completion_tokens + (usage[:completion_tokens] || 0),
        cost_usd: Decimal.add(run.cost_usd, decimal(usage[:cost_usd]))
      })

    run
  end

  # Writes the changes only if the row still has the status the caller read, and returns the
  # row as stored.
  defp move(run, changes) do
    changeset = KitchenRun.change(run, changes)

    cond do
      not changeset.valid? ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset

      changeset.changes == %{} ->
        {:ok, run}

      true ->
        query =
          from(r in KitchenRun, where: r.id == ^run.id and r.status == ^run.status, select: r)

        case Repo.update_all(query, [set: Map.to_list(changeset.changes)],
               household_id: run.household_id
             ) do
          {1, [moved]} -> {:ok, moved}
          {0, []} -> {:error, {:status_changed, current_status(run)}}
        end
    end
  end

  defp current_status(run) do
    case get(Scope.for_household(run.household_id), run.id) do
      %KitchenRun{status: status} -> status
      nil -> :not_found
    end
  end

  defp fetch(scope, run_id) do
    case get(scope, run_id) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  defp broadcast(run) do
    Phoenix.PubSub.broadcast(
      Tore.PubSub,
      topic(Scope.for_household(run.household_id)),
      {:run_changed, run}
    )
  end

  defp decimal(nil), do: Decimal.new(0)
  defp decimal(%Decimal{} = d), do: d
  defp decimal(n) when is_integer(n), do: Decimal.new(n)
  defp decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp now, do: DateTime.utc_now()

  # ----- undo --------------------------------------------------------------------------------

  # Each step restores one thing. A step this has no clause for raises, which rolls the whole
  # revert back: there is no undo that reports success without undoing.
  defp undo!(scope, {:steps, steps}),
    do: steps |> Enum.reverse() |> Enum.each(&undo_step!(scope, &1))

  # A receipt or recipe someone has since deleted is already undone.
  defp undo_step!(scope, {:delete_receipt, id}) do
    case Tore.Costs.delete_receipt(scope, id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp undo_step!(scope, {:restore_plan_slots, plan_id, befores}),
    do: :ok = Tore.Planning.restore_slots(scope, plan_id, befores)

  defp undo_step!(scope, {:restore_pantry_item, id, before}),
    do: :ok = Tore.Pantry.restore_item(scope, id, before)

  defp undo_step!(scope, {:delete_recipe, id}) do
    with %Tore.Recipes.Recipe{} = recipe <- Tore.Recipes.get(scope, id),
         do: {:ok, _} = Tore.Recipes.delete(scope, recipe)

    :ok
  end

  defp undo_step!(scope, {:restore_memory, added, forgotten}),
    do: :ok = Tore.Household.Memory.restore(scope, added, forgotten)
end
