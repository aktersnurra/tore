defmodule Tore.LLM.PlannerAgent do
  @moduledoc """
  Bounded tool-calling loop. Pure: no DB writes, no system-prompt construction,
  no correlation-id generation. Called by `Tore.Harness.Orchestrator`.
  """

  alias Tore.LLM.{Tool, PlannerTools}
  alias Tore.Harness.Handles

  @default_max_round_trips 6
  @default_max_action_calls 12

  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          cost_usd: Decimal.t()
        }

  @type trace_step :: %{
          step_index: non_neg_integer(),
          step_kind: :tool_calls | :tool_result | :message,
          payload: map()
        }

  @type result ::
          {:message, String.t()}
          | {:question, String.t()}
          | {:capped, String.t()}
          | {:proposal, struct(), map()}

  @type loop_outcome :: %{
          result: result(),
          tool_trace: [trace_step()],
          usage_per_step: [usage()],
          working_plan: term(),
          plan_events: [struct()]
        }

  @spec run(String.t(), String.t(), map(), keyword()) :: {:ok, loop_outcome()} | {:error, term()}
  def run(system_prompt, user_text, ctx, opts \\ []) do
    max_round_trips = Keyword.get(opts, :max_round_trips, @default_max_round_trips)
    max_action_calls = Keyword.get(opts, :max_action_calls, @default_max_action_calls)

    tools = PlannerTools.all() ++ Map.get(ctx, :extra_tools, [])
    tools_json = Enum.map(tools, &Tool.to_openai/1)

    state = %{
      ctx: ctx,
      tools_by_name: Map.new(tools, &{&1.name, &1}),
      tools_json: tools_json,
      messages: [%{role: "user", content: user_text}],
      tool_trace: [],
      usage_per_step: [],
      step_index: 0,
      action_calls: 0,
      round_trips: 0,
      max_round_trips: max_round_trips,
      max_action_calls: max_action_calls,
      working_plan: Map.fetch!(ctx, :working_plan),
      plan_events: [],
      handles: Map.get(ctx, :handles, %{})
    }

    loop(system_prompt, state)
  end

  # ---------- Loop ----------

  defp scope(state), do: Tore.Scope.for_household(state.ctx.household_id)

  defp loop(system, %{round_trips: rt, max_round_trips: max} = state) when rt >= max do
    case Tore.LLM.chat_with_tools(scope(state), system, state.messages, [], feature: :planner) do
      {:ok, {:message, text}, usage} ->
        finish(record_step(state, :message, %{text: text}, usage), {:capped, text})

      {:ok, _other, usage} ->
        finish(
          record_step(state, :message, %{text: ""}, usage),
          {:capped, "Stopped — too many steps."}
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp loop(system, state) do
    case Tore.LLM.chat_with_tools(scope(state), system, state.messages, state.tools_json,
           feature: :planner
         ) do
      {:ok, {:message, text}, usage} ->
        finish(record_step(state, :message, %{text: text}, usage), {:message, text})

      {:ok, {:tool_calls, calls}, usage} ->
        state =
          state
          |> record_step(:tool_calls, %{calls: encode_calls(calls)}, usage)
          |> Map.update!(:round_trips, &(&1 + 1))
          |> append_assistant_tool_calls(calls)

        case execute_calls(calls, state) do
          {:terminal_question, q, state} ->
            finish(state, {:question, q})

          {:terminal_proposal, proposal, pending, state} ->
            finish(state, {:proposal, proposal, pending})

          {:cap_hit, state} ->
            loop(system, %{state | round_trips: state.max_round_trips})

          {:continue, state} ->
            loop(system, state)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_calls([], state), do: {:continue, state}

  defp execute_calls([call | rest], state) do
    case Map.fetch(state.tools_by_name, call.name) do
      :error ->
        execute_calls(rest, append_tool_result(state, call, %{error: "unknown_tool"}))

      {:ok, tool} ->
        handle_tool(tool, call, rest, state)
    end
  end

  defp handle_tool(%Tool{name: "ask_user"} = tool, call, _rest, state) do
    case Tool.validate_args(tool, call.args) do
      :ok ->
        {:ok, %{ask_user: question}, [], _plan} =
          tool.run.(call.args, state.ctx, state.working_plan)

        state = append_tool_result(state, call, %{ok: true, question: question})
        {:terminal_question, question, state}

      {:error, _} = err ->
        {:continue, append_tool_result(state, call, %{error: inspect(err)})}
    end
  end

  defp handle_tool(%Tool{kind: :action} = tool, call, rest, state) do
    if state.action_calls >= state.max_action_calls do
      state = append_tool_result(state, call, %{error: "action_cap_reached"})

      state =
        Enum.reduce(rest, state, fn pending, acc ->
          append_tool_result(acc, pending, %{error: "action_cap_reached"})
        end)

      {:cap_hit, state}
    else
      state = %{state | action_calls: state.action_calls + 1}

      case exchange_recipe_ref(call, state) do
        {:ok, call} ->
          run_and_record(tool, call, rest, state)

        {:error, ref} ->
          message =
            "unknown recipe_ref #{inspect(ref)} — call search_recipes or resolve_recipe first and use a ref from the result"

          execute_calls(rest, append_tool_result(state, call, %{error: message}))
      end
    end
  end

  defp handle_tool(%Tool{kind: :read} = tool, call, rest, state) do
    run_and_record(tool, call, rest, state)
  end

  defp run_and_record(tool, call, rest, state) do
    case Tool.validate_args(tool, call.args) do
      :ok ->
        # Handles registered mid-loop live in state.handles, not the ctx captured
        # at start. Read tools that resolve a ref themselves (generate_recipe_variant)
        # need the live registry, or a ref from resolve_recipe reads as unknown.
        case tool.run.(call.args, tool_ctx(state), state.working_plan) do
          # A proposal ends the loop: the run parks in :needs_user for the
          # user to confirm, so there is nothing more for the model to do.
          {:proposal, proposal, pending, next_plan} ->
            state =
              %{state | working_plan: next_plan}
              |> append_tool_result(call, %{
                ok: true,
                proposal: proposal.title,
                awaiting_user: true
              })

            state =
              Enum.reduce(rest, state, fn superseded, acc ->
                append_tool_result(acc, superseded, %{error: "superseded_by_proposal"})
              end)

            {:terminal_proposal, proposal, pending, state}

          {:ok, result, events, next_plan} ->
            {handles, result} = Map.pop(result, :__handles__)

            state = %{
              state
              | working_plan: next_plan,
                plan_events: state.plan_events ++ events,
                handles: register_handles(state.handles, handles)
            }

            execute_calls(rest, append_tool_result(state, call, result))

          {:error, reason} ->
            execute_calls(rest, append_tool_result(state, call, %{error: inspect(reason)}))
        end

      {:error, reason} ->
        execute_calls(rest, append_tool_result(state, call, %{error: inspect(reason)}))
    end
  end

  defp tool_ctx(state), do: Map.put(state.ctx, :handles, state.handles)

  defp register_handles(registry, nil), do: registry

  defp register_handles(registry, handles) when is_list(handles) do
    Enum.reduce(handles, registry, &Handles.register(&2, &1))
  end

  defp exchange_recipe_ref(%{args: %{"recipe_ref" => ref} = args} = call, state) do
    case Handles.fetch(state.handles, ref) do
      {:ok, %Handles.ResolvedRecipe{} = handle} ->
        {:ok, %{call | args: Map.put(args, "recipe_id", handle.id)}}

      # A ref that exists but is not a recipe handle is as unusable here as an
      # invented one — reject it the same way rather than crash on a missing :id.
      {:ok, _other} ->
        {:error, ref}

      :error ->
        {:error, ref}
    end
  end

  defp exchange_recipe_ref(call, _state), do: {:ok, call}

  defp append_tool_result(state, call, result) do
    msg = %{
      role: "tool",
      tool_call_id: call.id,
      name: call.name,
      content: Jason.encode!(result)
    }

    state
    |> Map.update!(:messages, &(&1 ++ [msg]))
    |> record_trace(:tool_result, %{tool_call_id: call.id, name: call.name, result: result})
  end

  defp append_assistant_tool_calls(state, calls) do
    msg = %{
      role: "assistant",
      content: nil,
      tool_calls:
        Enum.map(calls, fn call ->
          %{
            id: call.id,
            type: "function",
            function: %{name: call.name, arguments: Jason.encode!(call.args)}
          }
        end)
    }

    Map.update!(state, :messages, &(&1 ++ [msg]))
  end

  defp finish(state, result) do
    {:ok,
     %{
       result: result,
       tool_trace: Enum.reverse(state.tool_trace),
       usage_per_step: Enum.reverse(state.usage_per_step),
       working_plan: state.working_plan,
       plan_events: state.plan_events
     }}
  end

  defp record_step(state, step_kind, payload, usage) do
    state
    |> record_trace(step_kind, payload)
    |> Map.update!(:usage_per_step, &[usage_struct(usage) | &1])
  end

  defp record_trace(state, step_kind, payload) do
    entry = %{step_index: state.step_index, step_kind: step_kind, payload: payload}

    state
    |> Map.update!(:tool_trace, &[entry | &1])
    |> Map.update!(:step_index, &(&1 + 1))
  end

  defp usage_struct(usage) when is_map(usage) do
    %{
      prompt_tokens: Map.get(usage, :prompt_tokens, 0),
      completion_tokens: Map.get(usage, :completion_tokens, 0),
      cost_usd: to_decimal(Map.get(usage, :cost_usd, 0))
    }
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)

  defp encode_calls(calls), do: Jason.encode!(calls)
end
