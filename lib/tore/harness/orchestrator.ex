defmodule Tore.Harness.Orchestrator do
  require Logger
  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Commands, State}
  alias Tore.Harness.Artifact.RunSummary
  alias Tore.Harness.PlanDiffBuilder
  alias Tore.AiOperations
  alias Tore.LLM.PlannerAgent
  alias Tore.Planning

  alias Tore.Harness.Verifier.{
    CostEntryVerifier,
    MemoryVerifier,
    PantryVerifier,
    PlanVerifier,
    RecipeProposalVerifier
  }

  alias Tore.Harness.Capsules

  alias Tore.Harness.{
    KitchenMemorySynthesis,
    PantryUpdate,
    ReceiptIngestion,
    UndoPayload
  }

  alias Tore.Harness.Artifact.{
    CostEntry,
    MemoryUpdate,
    PantryBeliefUpdate,
    PlanDiff,
    RecipeProposal,
    RunBundle
  }

  alias Tore.Recipes

  alias Tore.Harness.Capsules.{
    HouseholdPreferencesCapsule,
    ActiveInsightsCapsule,
    WeekPlanCapsule,
    PantryBeliefsCapsule
  }

  @planner_capsules [
    HouseholdPreferencesCapsule,
    ActiveInsightsCapsule,
    WeekPlanCapsule,
    PantryBeliefsCapsule
  ]

  @type dispatch_error :: {:step_failed, term()} | {:run_crashed, Exception.t()}

  @spec dispatch(atom(), map()) :: {:ok, State.t()} | {:error, dispatch_error()}

  def dispatch(:planner_command_run, ctx) do
    stream_id = Run.next_stream_id()
    metadata = %{household_id: ctx.household_id}
    scoped_slot = Map.get(ctx, :scoped_slot)

    open_cmd = %Commands.Open{
      household_id: ctx.household_id,
      kind: "planner_command_run",
      surface: :plan,
      started_by: Map.get(ctx, :started_by, "user"),
      user_id: ctx.user_id,
      input: %{
        command: ctx.command,
        plan_stream_id: ctx.plan_stream_id,
        week_start: ctx.week_start,
        scoped_slot: scoped_slot
      }
    }

    user_text = scoped_user_text(ctx.command, scoped_slot)

    run_dispatch(stream_id, metadata, "planner_command_run", fn ->
      with {:ok, state} <- open_run(stream_id, open_cmd, metadata),
           {:ok, state} <- enter(state, :gathering_context, metadata),
           {:ok, state} <- enter(state, :proposing, metadata),
           {:ok, state} <-
             run_planner_loop(state, ctx, stream_id, user_text, [], metadata) do
        {:ok, state}
      else
        {:error, reason} -> {:error, {:step_failed, reason}}
      end
    end)
  end

  defp scoped_user_text(command, nil), do: command

  defp scoped_user_text(command, scoped_slot) do
    label = humanize_slot(scoped_slot)
    "[The user is referring to #{label} (slot #{scoped_slot}).] " <> command
  end

  defp humanize_slot(slot_key), do: String.replace(slot_key, "_", " ")

  @weekly_max_round_trips 10
  @weekly_max_action_calls 25

  def dispatch(:receipt_ingestion_run, ctx) do
    stream_id = Map.get(ctx, :stream_id) || Run.next_stream_id()
    metadata = %{household_id: ctx.household_id}

    open_cmd = %Commands.Open{
      household_id: ctx.household_id,
      kind: "receipt_ingestion_run",
      surface: :plan,
      started_by: Map.get(ctx, :started_by, "user"),
      user_id: Map.get(ctx, :user_id),
      input: %{image_path: Map.get(ctx, :image_path)}
    }

    run_dispatch(stream_id, metadata, "receipt_ingestion_run", fn ->
      with {:ok, state} <- open_run(stream_id, open_cmd, metadata),
           {:ok, state} <- enter(state, :gathering_context, metadata),
           {:ok, parsed} <- ReceiptIngestion.parse(ctx.image_binary, household_locale()),
           {:ok, state} <- enter(state, :proposing, metadata),
           cost =
             ReceiptIngestion.build_cost_entry(parsed,
               date: Map.get(ctx, :date, Date.utc_today()),
               image_path: Map.get(ctx, :image_path)
             ),
           {:ok, state} <- enter(state, :verifying, metadata),
           {:ok, state} <- verify_and_surface_receipt(state, cost, metadata) do
        {:ok, state}
      else
        {:error, reason} ->
          Logger.error("receipt_ingestion_run step failed: #{inspect(reason, limit: :infinity)}")
          {:error, {:step_failed, reason}}
      end
    end)
  end

  def dispatch(:pantry_belief_update_run, ctx) do
    stream_id = Map.get(ctx, :stream_id) || Run.next_stream_id()
    metadata = %{household_id: ctx.household_id}
    channel = Map.fetch!(ctx, :channel)

    open_cmd = %Commands.Open{
      household_id: ctx.household_id,
      kind: "pantry_belief_update_run",
      surface: :plan,
      started_by: Map.get(ctx, :started_by, "user"),
      user_id: Map.get(ctx, :user_id),
      input: %{channel: Atom.to_string(channel), image_path: Map.get(ctx, :image_path)}
    }

    run_dispatch(stream_id, metadata, "pantry_belief_update_run", fn ->
      with {:ok, state} <- open_run(stream_id, open_cmd, metadata),
           {:ok, state} <- enter(state, :gathering_context, metadata),
           {:ok, items} <- gather_pantry_items(channel, ctx),
           artifact = PantryUpdate.build_artifact(items, channel),
           {:ok, state} <- enter(state, :proposing, metadata),
           {:ok, state} <- enter(state, :verifying, metadata),
           {:ok, state} <-
             verify_and_finish_pantry(state, artifact, metadata) do
        {:ok, state}
      else
        {:error, reason} -> {:error, {:step_failed, reason}}
      end
    end)
  end

  def dispatch(:kitchen_memory_synthesis_run, ctx) do
    stream_id = Run.next_stream_id()
    metadata = %{household_id: ctx.household_id}

    open_cmd = %Commands.Open{
      household_id: ctx.household_id,
      kind: "kitchen_memory_synthesis_run",
      surface: :plan,
      started_by: Map.get(ctx, :started_by, "system"),
      user_id: Map.get(ctx, :user_id),
      input: %{}
    }

    run_dispatch(stream_id, metadata, "kitchen_memory_synthesis_run", fn ->
      with {:ok, state} <- open_run(stream_id, open_cmd, metadata),
           {:ok, state} <- enter(state, :gathering_context, metadata),
           summary = KitchenMemorySynthesis.events_summary(memory_capsule_ctx(ctx)),
           {:ok, state} <- enter(state, :proposing, metadata),
           {:ok, insights} <- KitchenMemorySynthesis.synthesise(summary),
           artifact = KitchenMemorySynthesis.build_artifact(insights),
           {:ok, state} <- enter(state, :verifying, metadata),
           {:ok, state} <- verify_and_finish_memory(state, artifact, metadata) do
        {:ok, state}
      else
        {:error, reason} -> {:error, {:step_failed, reason}}
      end
    end)
  end

  def dispatch(:weekly_planning_run, ctx) do
    stream_id = Run.next_stream_id()
    metadata = %{household_id: ctx.household_id}

    open_cmd = %Commands.Open{
      household_id: ctx.household_id,
      kind: "weekly_planning_run",
      surface: :plan,
      started_by: "system",
      user_id: ctx.user_id,
      input: %{
        plan_stream_id: ctx.plan_stream_id,
        week_start: ctx.week_start
      }
    }

    opts = [max_round_trips: @weekly_max_round_trips, max_action_calls: @weekly_max_action_calls]

    run_dispatch(stream_id, metadata, "weekly_planning_run", fn ->
      with {:ok, state} <- open_run(stream_id, open_cmd, metadata),
           {:ok, state} <- enter(state, :gathering_context, metadata),
           {:ok, state} <- enter(state, :proposing, metadata),
           {:ok, state} <-
             run_planner_loop(state, ctx, stream_id, weekly_fill_instruction(), opts, metadata) do
        {:ok, state}
      else
        {:error, reason} -> {:error, {:step_failed, reason}}
      end
    end)
  end

  defp scoped_user_text(command, nil), do: command

  defp scoped_user_text(command, scoped_slot) do
    label = humanize_slot(scoped_slot)
    "[The user is referring to #{label} (slot #{scoped_slot}).] " <> command
  end

  defp humanize_slot(slot_key), do: String.replace(slot_key, "_", " ")

  @doc """
  Open a parent `:capture_turn_run` for a Capture turn. The router calls
  this at the start of `Router.route/4`, threads the returned stream id
  into the dispatch ctx for each tool call, then calls `end_turn/2` with
  the child stream ids the turn produced.

  The parent Run produces a single `RunBundle` artifact and commits a
  composite UndoPayload synthesised from its children's payloads — so
  one Capture turn = one receipt = one Undo.
  """
  @spec start_turn(map()) :: {:ok, String.t()} | {:error, term()}
  def start_turn(%{household_id: hh} = ctx) do
    sid = Run.next_stream_id()
    metadata = %{household_id: hh}

    cmd = %Commands.Open{
      household_id: hh,
      kind: "capture_turn_run",
      surface: :plan,
      started_by: Map.get(ctx, :started_by, "user"),
      user_id: Map.get(ctx, :user_id),
      input: %{}
    }

    case open_run(sid, cmd, metadata) do
      {:ok, _state} -> {:ok, sid}
      err -> err
    end
  end

  @doc """
  Close a parent `:capture_turn_run`. Walks the child Runs to collect
  their undo payloads, composes them, attaches a `RunBundle` artifact,
  and commits the parent.
  """
  @spec end_turn(Tore.Scope.t(), String.t(), [String.t()]) :: {:ok, State.t()} | {:error, term()}
  def end_turn(%Tore.Scope{} = scope, parent_sid, child_sids) when is_list(child_sids) do
    {:ok, state} = Run.load(scope, parent_sid)
    metadata = %{household_id: scope.household_id}

    bundle = %RunBundle{child_stream_ids: child_sids}
    payload = compose_children_payload(scope, child_sids)

    with %State.Running{} <- state,
         {:ok, state} <-
           apply_command(parent_sid, %Commands.AddArtifact{artifact: bundle}, state, metadata),
         {:ok, state} <-
           apply_command(parent_sid, %Commands.Commit{undo_payload: payload}, state, metadata) do
      {:ok, state}
    else
      %State.Applied{} = s -> {:ok, s}
      other -> {:error, other}
    end
  end

  @doc """
  Open a child Run for a single `set_plan_slot` tool call, assign the recipe
  in the planning aggregate, attach a `PlanDiff` artifact, and commit. The
  Router collects the returned stream id and passes it to `end_turn/2`.
  """
  @spec apply_set_plan_slot(map()) ::
          {:ok, %{stream_id: String.t(), recipe: map()}}
          | {:error, :recipe_not_found | term()}
  def apply_set_plan_slot(%{
        household_id: hh,
        user_id: uid,
        date: %Date{} = date,
        recipe_id: recipe_id,
        servings: servings
      }) do
    sid = Run.next_stream_id()
    metadata = %{household_id: hh}
    plan_id = Tore.Streams.plan(scope_for(hh), date)
    slot_key = slot_key_for_date(date)

    open_cmd = %Commands.Open{
      household_id: hh,
      kind: "set_plan_slot_run",
      surface: :plan,
      started_by: "user",
      user_id: uid,
      input: %{
        date: Date.to_iso8601(date),
        recipe_id: recipe_id,
        servings: servings,
        plan_stream_id: plan_id,
        slot_key: slot_key
      }
    }

    run_dispatch(sid, metadata, "set_plan_slot_run", fn ->
      with {:ok, recipe} <- fetch_recipe(scope_for(hh), recipe_id),
           {:ok, events} <-
             Planning.assign_recipe(scope_for(hh), plan_id, slot_key, recipe_id, servings),
           plan_diff = build_plan_diff(plan_id, date, slot_key, events, recipe),
           {:ok, state} <- open_run(sid, open_cmd, metadata),
           {:ok, state} <-
             apply_command(
               state.stream_id,
               %Commands.AddArtifact{artifact: plan_diff},
               state,
               metadata
             ),
           {:ok, _state} <-
             apply_command(state.stream_id, commit_command(state), state, metadata) do
        {:ok, %{stream_id: sid, recipe: recipe}}
      end
    end)
  end

  defp fetch_recipe(scope, recipe_id) do
    case Recipes.get!(scope, recipe_id) do
      %{} = r -> {:ok, r}
    end
  rescue
    Ecto.NoResultsError -> {:error, :recipe_not_found}
  end

  defp build_plan_diff(plan_id, date, slot_key, events, recipe) do
    week_start = Date.add(date, -(Date.day_of_week(date) - 1))

    diff_events =
      Enum.map(events, fn evt ->
        %{
          slot_key: slot_key,
          event_type: event_type_name(evt),
          payload: event_payload(evt, recipe),
          rationale: ["user requested"]
        }
      end)

    %PlanDiff{plan_stream_id: plan_id, week_start: week_start, events: diff_events}
  end

  defp event_type_name(%mod{}), do: mod |> Module.split() |> List.last()

  defp event_payload(%Tore.Planning.Events.RecipeAssigned{} = e, recipe) do
    %{"recipe_id" => e.recipe_id, "servings" => e.servings, "label" => recipe.title}
  end

  defp event_payload(_other, _recipe), do: %{}

  defp slot_key_for_date(%Date{} = date) do
    day = Enum.at(~w(mon tue wed thu fri sat sun), Date.day_of_week(date) - 1)
    "#{day}_dinner"
  end

  defp compose_children_payload(scope, child_sids) do
    child_sids
    |> Enum.map(fn sid ->
      case Run.load(scope, sid) do
        {:ok, %State.Applied{undo_payload: p}} -> p
        _ -> nil
      end
    end)
    |> UndoPayload.compose()
  end

  @doc """
  Commit a receipt proposal after the user has reviewed (and possibly edited)
  the cost on the `:needs_user` card. Re-runs the verifier against the
  (possibly edited) cost, then logs the receipt. UI entrypoint; not part of
  `dispatch/2`.
  """
  @spec commit_receipt(Tore.Scope.t(), String.t(), CostEntry.t(), integer() | nil) ::
          {:ok, State.t()} | {:error, term()}
  def commit_receipt(%Tore.Scope{} = scope, stream_id, %CostEntry{} = cost, user_id) do
    {:ok, state} = Run.load(scope, stream_id)
    metadata = %{household_id: scope.household_id}

    with %State.NeedsUser{} <- state,
         :ok <- CostEntryVerifier.verify(cost, %{}),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AnswerQuestion{answer: "confirmed"},
             state,
             metadata
           ),
         {:ok, _receipt} <- ReceiptIngestion.apply!(cost, user_id),
         {:ok, state} <-
           apply_command(state.stream_id, %Commands.AddArtifact{artifact: cost}, state, metadata),
         run_summary = RunSummary.from_artifacts([cost], :applied),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AddArtifact{artifact: run_summary},
             state,
             metadata
           ),
         {:ok, final_state} <-
           apply_command(state.stream_id, commit_command(state), state, metadata) do
      delete_run_photo_async(state)
      {:ok, final_state}
    else
      %State.Running{} -> {:error, :not_awaiting_user}
      %State.Applied{} -> {:error, :already_applied}
      %State.Failed{} -> {:error, :already_failed}
      {:fail, code, repair} -> {:error, {:verifier_failed, code, repair}}
      other -> {:error, other}
    end
  end

  @doc """
  Commit a recipe proposal after the user has reviewed (and possibly edited)
  it on the `:needs_user` card. Re-runs the verifier against the submitted
  proposal, saves the recipe to the catalog, and — if the run carried a
  pending slot assignment — assigns it. UI entrypoint; not part of
  `dispatch/2`.
  """
  @spec commit_recipe_proposal(Tore.Scope.t(), String.t(), RecipeProposal.t(), integer() | nil) ::
          {:ok, State.t()} | {:error, term()}
  def commit_recipe_proposal(
        %Tore.Scope{} = scope,
        stream_id,
        %RecipeProposal{} = proposal,
        user_id
      ) do
    {:ok, state} = Run.load(scope, stream_id)
    metadata = %{household_id: scope.household_id}

    with %State.NeedsUser{} <- state,
         :ok <- RecipeProposalVerifier.verify(proposal, recipe_proposal_ctx(scope)),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AnswerQuestion{answer: "confirmed"},
             state,
             metadata
           ),
         {:ok, recipe} <- Recipes.create(scope, recipe_attrs(proposal, user_id)),
         :ok <- assign_pending_slot(scope, state, proposal, recipe),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AddArtifact{artifact: proposal},
             state,
             metadata
           ),
         run_summary = RunSummary.from_artifacts([proposal], :applied),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AddArtifact{artifact: run_summary},
             state,
             metadata
           ) do
      apply_command(state.stream_id, commit_command(state), state, metadata)
    else
      %State.Running{} -> {:error, :not_awaiting_user}
      %State.Applied{} -> {:error, :already_applied}
      %State.Failed{} -> {:error, :already_failed}
      %State.Discarded{} -> {:error, :already_discarded}
      {:fail, code, repair} -> {:error, {:verifier_failed, code, repair}}
      other -> {:error, other}
    end
  end

  defp recipe_attrs(%RecipeProposal{} = proposal, user_id) do
    %{
      title: proposal.title,
      description: proposal.description,
      instructions: proposal.instructions,
      base_servings: proposal.base_servings,
      prep_time_minutes: proposal.prep_time_minutes,
      cook_time_minutes: proposal.cook_time_minutes,
      source_url: proposal.source_url,
      created_by: user_id,
      tags: proposal.tags,
      ingredients: Enum.map(proposal.ingredients, &recipe_ingredient_attrs/1)
    }
  end

  defp recipe_ingredient_attrs(ing) do
    %{name: ing[:name], quantity: to_decimal_quantity(ing[:quantity]), unit: ing[:unit]}
  end

  defp to_decimal_quantity(nil), do: nil
  defp to_decimal_quantity(%Decimal{} = d), do: d

  defp to_decimal_quantity(s) when is_binary(s) do
    case Decimal.parse(s) do
      {d, _rest} -> d
      :error -> nil
    end
  end

  defp to_decimal_quantity(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal_quantity(n) when is_float(n), do: Decimal.from_float(n)

  defp assign_pending_slot(_scope, _state, %RecipeProposal{pending_assignment: nil}, _recipe),
    do: :ok

  defp assign_pending_slot(scope, state, %RecipeProposal{pending_assignment: pending}, recipe) do
    slot_key = pending[:slot_key] || pending["slot_key"]
    servings = pending[:servings] || pending["servings"] || recipe.base_servings || 4

    case Planning.assign_recipe(
           scope,
           run_input(state, :plan_stream_id),
           slot_key,
           recipe.id,
           servings
         ) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp run_input(%{input: input}, key) do
    Map.get(input, key) || Map.get(input, Atom.to_string(key))
  end

  @doc """
  Discard a `:needs_user` run. Used by the user (`reason: :user_discarded`)
  and by the TTL sweep (`reason: :ttl_expired`). Records a `RunDiscarded`
  event and fire-and-forgets the photo cleanup.
  """
  @spec discard_run(Tore.Scope.t(), String.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def discard_run(%Tore.Scope{} = scope, stream_id, opts \\ []) do
    reason = Keyword.get(opts, :reason, :user_discarded)

    case Run.load(scope, stream_id) do
      {:ok, %State.NeedsUser{} = state} ->
        metadata = %{household_id: state.household_id}

        case apply_command(state.stream_id, %Commands.Discard{reason: reason}, state, metadata) do
          {:ok, new_state} ->
            delete_run_photo_async(state)
            {:ok, new_state}

          {:error, _} = err ->
            err
        end

      {:ok, %State.Discarded{}} ->
        {:error, :already_discarded}

      {:ok, %State.Applied{}} ->
        {:error, :already_applied}

      {:ok, _other} ->
        {:error, :not_discardable}
    end
  end

  # Fire-and-forget cleanup of the photo stashed at upload time. We don't
  # block the commit/discard on S3; the weekly orphan sweep is the safety net.
  defp delete_run_photo_async(state) do
    case state.input do
      %{image_path: path} when is_binary(path) and path != "" ->
        Tore.Storage.RunPhotos.delete_async(path)

      _ ->
        :ok
    end
  end

  defp open_run(sid, %Commands.Open{} = cmd, metadata) do
    apply_command(sid, cmd, %State.Draft{stream_id: sid}, metadata)
  end

  defp scope_for(household_id), do: Tore.Scope.for_household(household_id)

  defp household_locale do
    case Tore.Household.get_household!() do
      %{locale: locale} when is_binary(locale) -> locale
      _ -> nil
    end
  end

  defp run_dispatch(stream_id, metadata, kind, fun) do
    result =
      try do
        fun.()
      rescue
        e ->
          Logger.error("#{kind} crashed: " <> Exception.format(:error, e, __STACKTRACE__))

          {:error, {:run_crashed, e}}
      end

    case result do
      {:ok, state} ->
        {:ok, state}

      {:error, _} = err ->
        record_failure(stream_id, metadata)
        err
    end
  end

  defp run_planner_loop(state, ctx, stream_id, user_text, opts, metadata) do
    with {:ok, working_plan} <-
           Planning.load_plan(scope_for(ctx.household_id), ctx.plan_stream_id),
         {:ok, loop} <-
           PlannerAgent.run(
             system_prompt(ctx),
             user_text,
             agent_ctx(ctx, stream_id, working_plan),
             opts
           ),
         {:ok, state} <- absorb_loop(state, loop, metadata),
         {:ok, state} <- enter(state, :verifying, metadata),
         {:ok, state} <- close(state, loop, ctx, metadata) do
      {:ok, state}
    end
  end

  defp enter(state, phase, metadata),
    do: apply_command(state.stream_id, %Commands.EnterPhase{phase: phase}, state, metadata)

  defp absorb_loop(state, loop, metadata) do
    with {:ok, state} <- absorb_trace(state, loop, metadata) do
      absorb_usage(state, loop, metadata)
    end
  end

  defp absorb_trace(state, loop, metadata) do
    Enum.reduce_while(loop.tool_trace, {:ok, state}, fn entry, {:ok, acc} ->
      ai_op_id = log_ai_operation(acc.stream_id, entry)

      cmd = %Commands.RecordToolStep{
        step_index: entry.step_index,
        step_kind: entry.step_kind,
        payload: entry.payload,
        ai_operation_id: ai_op_id
      }

      case apply_command(acc.stream_id, cmd, acc, metadata) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp absorb_usage(state, loop, metadata) do
    Enum.reduce_while(loop.usage_per_step, {:ok, state}, fn usage, {:ok, acc} ->
      cmd = %Commands.ObserveModelUsage{
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        cost_usd: usage.cost_usd
      }

      case apply_command(acc.stream_id, cmd, acc, metadata) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp close(state, %{result: {:message, _}} = loop, ctx, metadata),
    do: verify_and_finish(state, loop, ctx, metadata)

  defp close(state, %{result: {:capped, _}} = loop, ctx, metadata),
    do: verify_and_finish(state, loop, ctx, metadata)

  defp close(state, %{result: {:question, q}}, _ctx, metadata),
    do: apply_command(state.stream_id, %Commands.RaiseQuestion{question: q}, state, metadata)

  defp close(state, %{result: {:proposal, proposal, pending}}, _ctx, metadata),
    do: verify_and_surface_proposal(state, proposal, pending, metadata)

  defp verify_and_finish(state, loop, ctx, metadata) do
    plan_diff = PlanDiffBuilder.build(loop.tool_trace, ctx)

    case PlanVerifier.verify(plan_diff, verify_ctx(loop, ctx)) do
      :ok ->
        run_summary = RunSummary.from_artifacts([plan_diff], :applied)

        with :ok <-
               Planning.apply_events(
                 scope_for(ctx.household_id),
                 ctx.plan_stream_id,
                 loop.plan_events
               ),
             {:ok, state} <-
               apply_command(
                 state.stream_id,
                 %Commands.AddArtifact{artifact: plan_diff},
                 state,
                 metadata
               ),
             {:ok, state} <-
               apply_command(
                 state.stream_id,
                 %Commands.AddArtifact{artifact: run_summary},
                 state,
                 metadata
               ) do
          apply_command(state.stream_id, commit_command(state), state, metadata)
        end

      {:fail, code, repair} ->
        apply_command(
          state.stream_id,
          %Commands.RecordFailure{code: code, user_message: nil, repair_action: repair},
          state,
          metadata
        )
    end
  end

  defp verify_and_surface_receipt(state, %CostEntry{} = cost, metadata) do
    # Per §A.6.1 a receipt transitions to NeedsUser when the verifier passes:
    # the user reviews on an editable card and commit_receipt/3 commits.
    with :ok <- CostEntryVerifier.verify(cost, %{}),
         {:ok, state} <-
           apply_command(state.stream_id, %Commands.AddArtifact{artifact: cost}, state, metadata) do
      apply_command(
        state.stream_id,
        %Commands.RaiseQuestion{question: "Review the parsed receipt before saving."},
        state,
        metadata
      )
    else
      {:fail, code, repair} ->
        apply_command(
          state.stream_id,
          %Commands.RecordFailure{code: code, user_message: nil, repair_action: repair},
          state,
          metadata
        )

      other ->
        other
    end
  end

  # SPEC §A.6.1: generated or imported recipe content never auto-commits. When
  # the verifier passes we park the run in :needs_user so the user reviews the
  # recipe on an editable card; commit_recipe_proposal/3 does the saving.
  defp verify_and_surface_proposal(state, %RecipeProposal{} = proposal, pending, metadata) do
    # The pending slot rides on the artifact: it is only known mid-loop, after
    # Commands.Open already wrote the run's input, and there is no command for
    # amending input.
    proposal = %{proposal | pending_assignment: normalise_pending(pending)}

    with :ok <-
           RecipeProposalVerifier.verify(
             proposal,
             recipe_proposal_ctx(scope_for(state.household_id))
           ),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AddArtifact{artifact: proposal},
             state,
             metadata
           ) do
      apply_command(
        state.stream_id,
        %Commands.RaiseQuestion{question: "Review this recipe before saving it."},
        state,
        metadata
      )
    else
      {:fail, code, repair} ->
        apply_command(
          state.stream_id,
          %Commands.RecordFailure{
            code: code,
            user_message: proposal_failure_message(code),
            repair_action: repair
          },
          state,
          metadata
        )

      other ->
        other
    end
  end

  defp proposal_failure_message(:near_duplicate),
    do: "You already have a recipe just like this one."

  defp proposal_failure_message(_code),
    do: "That recipe came back incomplete — nothing was saved."

  # An empty map means the planner asked for a recipe with no slot in mind.
  defp normalise_pending(pending) when pending == %{}, do: nil
  defp normalise_pending(pending), do: pending

  # The verifier is pure, so the catalog it compares against is gathered here.
  defp recipe_proposal_ctx(scope) do
    %{existing_recipes: Recipes.catalog_fingerprints(scope)}
  end

  defp gather_pantry_items(:shelf_photo, %{image_binary: bin} = ctx),
    do: PantryUpdate.parse_shelf_photo(scope_for(ctx.household_id), bin)

  defp gather_pantry_items(_, %{items: items}) when is_list(items), do: {:ok, items}
  defp gather_pantry_items(_, _), do: {:error, :missing_items}

  defp verify_and_finish_pantry(state, %PantryBeliefUpdate{} = artifact, metadata) do
    with :ok <- PantryVerifier.verify(artifact, %{scope: scope_for(state.household_id)}),
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AddArtifact{artifact: artifact},
             state,
             metadata
           ),
         {:ok, counts, snaps} <-
           PantryUpdate.apply!(scope_for(state.household_id), artifact, household_locale()),
         snapshot = %Tore.Harness.Artifact.PantrySnapshot{items: snaps},
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AddArtifact{artifact: snapshot},
             state,
             metadata
           ),
         run_summary = %RunSummary{counts: counts, outcome: :applied},
         {:ok, state} <-
           apply_command(
             state.stream_id,
             %Commands.AddArtifact{artifact: run_summary},
             state,
             metadata
           ) do
      apply_command(state.stream_id, commit_command(state), state, metadata)
    else
      {:fail, code, repair} ->
        apply_command(
          state.stream_id,
          %Commands.RecordFailure{code: code, user_message: nil, repair_action: repair},
          state,
          metadata
        )

      other ->
        other
    end
  end

  defp memory_capsule_ctx(ctx) do
    %{
      household_id: ctx.household_id,
      plan_stream_id: Map.get(ctx, :plan_stream_id),
      week_start: Map.get(ctx, :week_start)
    }
  end

  defp verify_and_finish_memory(state, %MemoryUpdate{} = artifact, metadata) do
    case MemoryVerifier.verify(artifact, %{max_active: KitchenMemorySynthesis.max_active()}) do
      :ok ->
        run_summary = RunSummary.from_artifacts([artifact], :applied)

        with {:ok, _} <- KitchenMemorySynthesis.apply!(artifact),
             {:ok, state} <-
               apply_command(
                 state.stream_id,
                 %Commands.AddArtifact{artifact: artifact},
                 state,
                 metadata
               ),
             {:ok, state} <-
               apply_command(
                 state.stream_id,
                 %Commands.AddArtifact{artifact: run_summary},
                 state,
                 metadata
               ) do
          apply_command(state.stream_id, commit_command(state), state, metadata)
        end

      {:fail, code, repair} ->
        apply_command(
          state.stream_id,
          %Commands.RecordFailure{code: code, user_message: nil, repair_action: repair},
          state,
          metadata
        )
    end
  end

  defp verify_ctx(loop, ctx) do
    %{
      plan_state: loop.working_plan,
      preferences: Tore.Household.get_preferences(),
      scope: scope_for(ctx.household_id)
    }
  end

  # On any dispatch failure, close the run as Failed so it isn't a dangling open
  # run the Projector replays forever. Only valid from Running (the Decider
  # rejects RecordFailure otherwise); a pre-Running failure persisted nothing to
  # close. Best-effort: a further append error is swallowed.
  defp record_failure(stream_id, metadata) do
    case Run.load(scope_for(metadata.household_id), stream_id) do
      {:ok, %State.Running{} = state} ->
        cmd = %Commands.RecordFailure{
          code: :internal_error,
          user_message: nil,
          repair_action: nil
        }

        _ = apply_command(stream_id, cmd, state, metadata)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp apply_command(stream_id, command, state, metadata) do
    with {:ok, events} <- Run.decide(command, state),
         :ok <- Run.append(scope_for(metadata.household_id), stream_id, events) do
      new_state = Enum.reduce(events, state, fn ev, acc -> Run.evolve(acc, ev) end)
      {:ok, new_state}
    end
  end

  # Derive the UndoPayload from the run's artifacts at commit time so
  # State.Applied carries everything Phase 3 compensators need.
  defp commit_command(%{artifacts: artifacts}),
    do: %Commands.Commit{undo_payload: UndoPayload.from_artifacts(artifacts)}

  defp log_ai_operation(stream_id, entry) do
    {:ok, op} =
      AiOperations.log(%{
        run_stream_id: stream_id,
        kind: "planner_agent." <> Atom.to_string(entry.step_kind),
        step_index: entry.step_index,
        payload: Jason.encode!(entry.payload),
        result: ""
      })

    op.id
  end

  defp system_prompt(ctx) do
    [
      agent_preamble(),
      date_line(),
      week_mode_line(ctx),
      Capsules.compose(@planner_capsules, capsule_ctx(ctx))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp date_line do
    "Today is #{Calendar.strftime(Date.utc_today(), "%A, %B %-d, %Y")}."
  end

  defp week_mode_line(ctx) do
    case Tore.WeekMode.mode_prompt_fragment(
           Tore.WeekMode.get_current_mode(scope_for(ctx.household_id))
         ) do
      nil -> nil
      fragment -> "Current week mode: #{fragment}"
    end
  end

  defp capsule_ctx(ctx) do
    %{
      household_id: ctx.household_id,
      plan_stream_id: ctx.plan_stream_id,
      week_start: ctx.week_start
    }
  end

  defp agent_ctx(ctx, stream_id, working_plan) do
    %{
      plan_id: ctx.plan_stream_id,
      week_start: ctx.week_start,
      household_id: ctx.household_id,
      run_stream_id: stream_id,
      working_plan: working_plan,
      handles: scoped_handles(Map.get(ctx, :scoped_slot)),
      # PlannerAgent appends these to PlannerTools.all/0. Nothing in production
      # sets it; it is the seam tests use to drive the loop with a stub tool.
      extra_tools: Map.get(ctx, :extra_tools, [])
    }
  end

  defp scoped_handles(nil), do: %{}

  defp scoped_handles(scoped_slot) do
    handle = Tore.Harness.Handles.slot(scoped_slot, humanize_slot(scoped_slot))
    Tore.Harness.Handles.register(%{}, handle)
  end

  defp weekly_fill_instruction do
    """
    Fill every empty, unplanned dinner this week with a suitable recipe. Leave
    days that already have a meal, days the household has pinned, and days marked
    eating_out exactly as they are. Use leftovers across days where it makes
    sense. When you are done, stop.
    """
  end

  defp agent_preamble do
    """
    You are the planner agent for Tore, a household meal planner.

    You operate by calling tools, not by replying in prose. When the user makes
    a request that maps to a planning action (assign, swap, skip, mark as
    leftovers, set servings, remove), call the corresponding tool. When you
    need to look up recipes, pantry, or deals to decide what to do, call the
    matching read tool first. Recipes are referenced by the `ref` returned
    from search_recipes or resolve_recipe — never invent or guess a ref, and
    never reuse a ref from an earlier turn. When the user refers to a slot in
    natural language ("tonight", a weekday, "the salmon dinner") instead of
    naming a slot key, call resolve_slot to get the structural slot_key
    before calling a slot-targeting action. When resolve_recipe or
    resolve_slot returns multiple ambiguous matches, or the user's request is
    otherwise ambiguous, call ask_user with a specific clarifying question
    instead of guessing.

    After your tool calls succeed, give a one-sentence confirmation of what you
    did. Do not narrate or restate the plan. If you cannot perform the action
    (a tool returned an error), explain what went wrong in one sentence.

    Always prefer calling a tool over describing what you would do.
    When you call an action tool, always include a short `rationale` saying why.
    """
  end
end
