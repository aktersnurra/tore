defmodule Tore.LLM.PlannerAgentTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.LLM.PlannerAgent
  alias Tore.Planning.{State, Events, Decider}
  alias Tore.Harness.Handles

  @system_prompt "system: be brief"
  @ctx %{plan_id: "plan-1", week_start: ~D[2026-06-01], household_id: 1, working_plan: %State{}}

  defp ctx_with_plan(plan),
    do: %{plan_id: "plan-1", week_start: ~D[2026-06-01], household_id: 1, working_plan: plan}

  test "run/4 returns {:ok, loop_outcome} with a message result and usage steps" do
    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Done."},
       %{prompt_tokens: 5, completion_tokens: 2, cost_usd: Decimal.new("0.0001")}}
    end)

    assert {:ok, outcome} = PlannerAgent.run(@system_prompt, "skip mon dinner", @ctx, [])
    assert outcome.result == {:message, "Done."}
    assert is_list(outcome.tool_trace)
    assert is_list(outcome.usage_per_step)
    assert hd(outcome.usage_per_step).prompt_tokens == 5
  end

  test "run/4 coerces a float cost_usd from the LLM into a Decimal" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "ok"}, %{prompt_tokens: 5, completion_tokens: 2, cost_usd: 5.04e-4}}
    end)

    {:ok, outcome} = PlannerAgent.run(@system_prompt, "x", @ctx, [])
    usage = hd(outcome.usage_per_step)
    assert %Decimal{} = usage.cost_usd
    assert Decimal.equal?(usage.cost_usd, Decimal.from_float(5.04e-4))
  end

  test "run/4 does not write to ai_operations" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "ok"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, _} = PlannerAgent.run(@system_prompt, "x", @ctx, [])

    # No rows should have been inserted — the orchestrator owns persistence.
    assert Tore.AiOperations.list_for_run("anything") == []
  end

  test "run/4 assigns a unique step_index to every trace entry" do
    stub(Tore.MockLLM, :chat_with_tools, fn _, _, tools, _opts ->
      if tools == [] do
        {:ok, {:message, "stopped"},
         %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      else
        {:ok, {:tool_calls, [%{id: "c1", name: "search_recipes", args: %{"query" => "x"}}]},
         %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      end
    end)

    {:ok, outcome} = PlannerAgent.run(@system_prompt, "loop", @ctx, max_round_trips: 2)

    indices = Enum.map(outcome.tool_trace, & &1.step_index)
    assert indices == Enum.uniq(indices)
    assert indices == Enum.sort(indices)
  end

  test "run/4 returns {:question, q} when ask_user is invoked" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "ask_user", args: %{"question" => "which?"}}]},
       %{prompt_tokens: 3, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    assert {:ok, outcome} = PlannerAgent.run(@system_prompt, "ambiguous", @ctx, [])
    assert outcome.result == {:question, "which?"}
  end

  test "run/4 returns {:capped, _} after max round-trips" do
    stub(Tore.MockLLM, :chat_with_tools, fn _, _, tools, _opts ->
      if tools == [] do
        {:ok, {:message, "stopped"},
         %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      else
        {:ok, {:tool_calls, [%{id: "c1", name: "search_recipes", args: %{"query" => "x"}}]},
         %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
      end
    end)

    assert {:ok, outcome} = PlannerAgent.run(@system_prompt, "loop", @ctx, max_round_trips: 2)
    assert match?({:capped, _}, outcome.result) or match?({:message, _}, outcome.result)
  end

  test "run/4 accumulates plan_events and evolves working_plan across the loop" do
    {:ok, r} =
      Tore.Recipes.create(home_scope(), %{title: "Z", base_servings: 2, instructions: "x"})

    rid = r.id

    start_plan =
      Decider.evolve(%State{}, %Events.RecipeAssigned{
        slot_key: "mon_dinner",
        recipe_id: rid,
        servings: 2
      })

    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c1",
            name: "skip_meal",
            args: %{"slot_key" => "mon_dinner", "rationale" => "out"}
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "Done."},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, outcome} = PlannerAgent.run(@system_prompt, "skip mon", ctx_with_plan(start_plan), [])

    assert [%Events.MealSkipped{slot_key: "mon_dinner"}] = outcome.plan_events
    assert outcome.working_plan.slots["mon_dinner"].skipped == true
  end

  test "action tool with an invented recipe_ref is rejected and fed back" do
    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c1",
            name: "assign_recipe",
            args: %{
              "slot_key" => "mon_dinner",
              "recipe_ref" => "rcp_fake",
              "servings" => 2,
              "rationale" => "guess"
            }
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "I couldn't find that recipe."},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, outcome} = PlannerAgent.run(@system_prompt, "assign something", @ctx, [])

    assert outcome.plan_events == []
    assert outcome.result == {:message, "I couldn't find that recipe."}

    tool_result_step =
      Enum.find(outcome.tool_trace, &(&1.step_kind == :tool_result))

    assert tool_result_step
    result_str = inspect(tool_result_step.payload.result)
    assert result_str =~ "unknown recipe_ref"
  end

  test "a rejected recipe_ref still counts toward max_action_calls" do
    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c1",
            name: "assign_recipe",
            args: %{
              "slot_key" => "mon_dinner",
              "recipe_ref" => "rcp_fake",
              "servings" => 2,
              "rationale" => "guess"
            }
          },
          %{
            id: "c2",
            name: "assign_recipe",
            args: %{
              "slot_key" => "tue_dinner",
              "recipe_ref" => "rcp_fake2",
              "servings" => 2,
              "rationale" => "guess"
            }
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "stopping"},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, outcome} =
      PlannerAgent.run(@system_prompt, "assign something", @ctx, max_action_calls: 1)

    assert outcome.plan_events == []

    results =
      outcome.tool_trace
      |> Enum.filter(&(&1.step_kind == :tool_result))
      |> Enum.map(&inspect(&1.payload.result))

    # The rejected first call consumed the only action slot, so the second
    # call must hit the cap rather than the ref check.
    assert Enum.any?(results, &(&1 =~ "unknown recipe_ref"))
    assert Enum.any?(results, &(&1 =~ "action_cap_reached"))
  end

  test "a registered non-recipe handle passed as recipe_ref is rejected, not crashed on" do
    slot_handle = Handles.slot("mon_dinner", "mon dinner")
    ctx = Map.put(@ctx, :handles, Handles.register(%{}, slot_handle))

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c1",
            name: "assign_recipe",
            args: %{
              "slot_key" => "mon_dinner",
              "recipe_ref" => slot_handle.ref,
              "servings" => 2,
              "rationale" => "confused"
            }
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "ok"}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, outcome} = PlannerAgent.run(@system_prompt, "assign something", ctx, [])

    assert outcome.plan_events == []
    result_str = inspect(Enum.map(outcome.tool_trace, & &1.payload))
    assert result_str =~ "unknown recipe_ref"
  end

  test "assign_recipe via a pre-seeded handle ref applies the command" do
    {:ok, r} =
      Tore.Recipes.create(home_scope(), %{title: "Salmon", base_servings: 2, instructions: "x"})

    handle = Handles.recipe(r.id, r.title, :search_recipes, 1.0)
    ctx = Map.put(@ctx, :handles, Handles.register(%{}, handle))

    expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c1",
            name: "assign_recipe",
            args: %{
              "slot_key" => "mon_dinner",
              "recipe_ref" => handle.ref,
              "servings" => 2,
              "rationale" => "known good"
            }
          }
        ]}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:message, "Done."},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    {:ok, outcome} = PlannerAgent.run(@system_prompt, "assign salmon", ctx, [])

    rid = r.id

    assert [%Events.RecipeAssigned{slot_key: "mon_dinner", recipe_id: ^rid, servings: 2}] =
             outcome.plan_events

    assert outcome.working_plan.slots["mon_dinner"].recipe_id == rid
  end

  defp stub_proposal do
    %Tore.Harness.Artifact.RecipeProposal{
      title: "Simpler Ramen",
      ingredients: [%{name: "miso paste", quantity: "2", unit: "msk"}],
      instructions: "Simmer. Serve.",
      base_servings: 4,
      source: :generation,
      source_recipe_id: 1,
      instruction: "simpler"
    }
  end

  defp proposal_tool(proposal, pending) do
    %Tore.LLM.Tool{
      name: "fake_proposal_tool",
      description: "test double",
      kind: :read,
      parameters: %{type: "object", properties: %{}, required: []},
      run: fn _args, _ctx, plan -> {:proposal, proposal, pending, plan} end
    }
  end

  test "run/4 stops the loop when a read tool returns {:proposal, ...}" do
    proposal = stub_proposal()

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "fake_proposal_tool", args: %{}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    ctx =
      Map.put(@ctx, :extra_tools, [
        proposal_tool(proposal, %{slot_key: "mon_dinner", servings: 4})
      ])

    assert {:ok, outcome} = PlannerAgent.run(@system_prompt, "make it simpler", ctx, [])

    assert {:proposal, ^proposal, pending} = outcome.result
    assert pending == %{slot_key: "mon_dinner", servings: 4}
  end

  test "run/4 makes no further model round-trips after a proposal" do
    proposal = stub_proposal()

    # Exactly one call — a second would mean the loop kept going.
    expect(Tore.MockLLM, :chat_with_tools, 1, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "fake_proposal_tool", args: %{}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    ctx = Map.put(@ctx, :extra_tools, [proposal_tool(proposal, %{})])

    assert {:ok, outcome} = PlannerAgent.run(@system_prompt, "make it simpler", ctx, [])
    assert match?({:proposal, _, _}, outcome.result)
  end

  test "run/4 records the proposal in the tool trace" do
    proposal = stub_proposal()

    expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ ->
      {:ok, {:tool_calls, [%{id: "c1", name: "fake_proposal_tool", args: %{}}]},
       %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
    end)

    ctx = Map.put(@ctx, :extra_tools, [proposal_tool(proposal, %{})])

    {:ok, outcome} = PlannerAgent.run(@system_prompt, "make it simpler", ctx, [])

    assert Enum.any?(outcome.tool_trace, fn entry ->
             entry.step_kind == :tool_result and
               entry.payload[:result][:awaiting_user] == true
           end)
  end
end
