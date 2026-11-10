defmodule Tore.Harness.OrchestratorSystemPromptTest do
  use Tore.DataCase, async: false
  import Mox

  setup :verify_on_exit!

  alias Tore.Harness.Orchestrator

  defp this_week_start do
    today = Date.utc_today()
    Date.add(today, -(Date.day_of_week(today) - 1))
  end

  test "the planner run's system prompt carries the composed household + week context" do
    {:ok, _} =
      Tore.Household.update_preferences(home_scope(), %{dietary_restrictions: ["vegetarian"]})

    test_pid = self()

    Mox.expect(Tore.MockLLM, :chat_with_tools, fn sys, _msgs, _tools, _opts ->
      send(test_pid, {:system_prompt, sys})
      {:ok, {:message, "Done."}, %{}}
    end)

    week_start = this_week_start()

    ctx = %{
      household_id: 1,
      user_id: nil,
      command: "what's for dinner",
      plan_stream_id: Tore.Streams.plan(home_scope(), week_start),
      week_start: week_start
    }

    {:ok, _state} = Orchestrator.dispatch(:planner_command_run, ctx)

    assert_receive {:system_prompt, sys}
    assert sys =~ "You are the planner agent for Tore"
    assert sys =~ "Household preferences:"
    assert sys =~ "This week's dinner plan:"
    refute sys =~ "friendly and practical AI cooking and meal planning assistant"
  end
end
