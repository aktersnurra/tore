defmodule Tore.Harness.WeeklyPlanningRunTest do
  use Tore.DataCase, async: false
  import Mox

  setup :verify_on_exit!

  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run.State
  alias Tore.{Planning, Recipes}

  defp ctx_for(week_start) do
    %{
      household_id: home_scope().household_id,
      user_id: nil,
      plan_stream_id: Tore.Streams.plan(home_scope(), week_start),
      week_start: week_start
    }
  end

  test "fills empty unpinned slots and leaves pinned + assigned slots untouched" do
    week_start = ~D[2026-06-15]
    ctx = ctx_for(week_start)

    {:ok, chosen} =
      Recipes.create(home_scope(), %{
        title: "Lentil stew",
        recipe_type: :meal,
        base_servings: 4,
        prep_time_minutes: 10,
        cook_time_minutes: 30
      })

    {:ok, pinned_recipe} =
      Recipes.create(home_scope(), %{
        title: "Pinned pasta",
        recipe_type: :meal,
        base_servings: 4,
        prep_time_minutes: 5,
        cook_time_minutes: 15
      })

    Planning.assign_recipe(home_scope(), ctx.plan_stream_id, "mon_dinner", pinned_recipe.id, 4)
    Planning.pin_slot(home_scope(), ctx.plan_stream_id, "mon_dinner", true)
    Planning.assign_recipe(home_scope(), ctx.plan_stream_id, "tue_dinner", chosen.id, 4)

    Mox.expect(Tore.MockLLM, :chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok,
       {:tool_calls,
        [
          %{
            id: "c1",
            name: "resolve_recipe",
            args: %{"query" => "Lentil stew"}
          }
        ]}, %{prompt_tokens: 10, completion_tokens: 5, cost_usd: 0.0001}}
    end)
    |> Mox.expect(:chat_with_tools, fn _sys, msgs, _tools, _opts ->
      ref =
        msgs
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{role: "tool", name: "resolve_recipe", content: content} ->
            %{"match" => %{"ref" => ref}} = Jason.decode!(content)
            ref

          _ ->
            nil
        end)

      {:ok,
       {:tool_calls,
        [
          %{
            id: "c2",
            name: "assign_recipe",
            args: %{
              "slot_key" => "wed_dinner",
              "recipe_ref" => ref,
              "servings" => 4,
              "rationale" => "Filling empty slot"
            }
          }
        ]}, %{prompt_tokens: 10, completion_tokens: 5, cost_usd: 0.0001}}
    end)
    |> Mox.expect(:chat_with_tools, fn _sys, _msgs, _tools, _opts ->
      {:ok, {:message, "Filled the week."},
       %{prompt_tokens: 4, completion_tokens: 2, cost_usd: 0.0}}
    end)

    assert {:ok, %State.Applied{}} = Orchestrator.dispatch(:weekly_planning_run, ctx)

    {:ok, plan} = Planning.load_plan(home_scope(), ctx.plan_stream_id)
    assert plan.slots["wed_dinner"].recipe_id == chosen.id
    assert plan.slots["mon_dinner"].recipe_id == pinned_recipe.id
    assert Map.has_key?(plan.pins, "mon_dinner")
    assert plan.slots["tue_dinner"].recipe_id == chosen.id
  end
end
