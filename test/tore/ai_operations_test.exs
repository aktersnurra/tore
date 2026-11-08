defmodule Tore.AiOperationsTest do
  use Tore.DataCase, async: false
  alias Tore.AiOperations
  alias Tore.AiOperations.AiOperation

  test "log/1 with run_stream_id inserts a row" do
    {:ok, op} =
      AiOperations.log(home_scope(), %{
        run_stream_id: "run-abc",
        kind: "planner_agent.message",
        step_index: 0,
        payload: "{}",
        result: "ok"
      })

    assert op.run_stream_id == "run-abc"
    assert op.kind == "planner_agent.message"
  end

  test "list_for_run/1 returns rows ordered by step_index" do
    AiOperations.log(home_scope(), %{
      run_stream_id: "run-x",
      kind: "k",
      step_index: 1,
      payload: "{}",
      result: "a"
    })

    AiOperations.log(home_scope(), %{
      run_stream_id: "run-x",
      kind: "k",
      step_index: 0,
      payload: "{}",
      result: "b"
    })

    AiOperations.log(home_scope(), %{
      run_stream_id: "run-x",
      kind: "k",
      step_index: 2,
      payload: "{}",
      result: "c"
    })

    rows = AiOperations.list_for_run(home_scope(), "run-x")
    assert Enum.map(rows, & &1.step_index) == [0, 1, 2]
  end

  test "unique constraint on (run_stream_id, step_index)" do
    AiOperations.log(home_scope(), %{
      run_stream_id: "run-y",
      kind: "k",
      step_index: 0,
      payload: "{}",
      result: "a"
    })

    assert {:error, changeset} =
             AiOperations.log(home_scope(), %{
               run_stream_id: "run-y",
               kind: "k",
               step_index: 0,
               payload: "{}",
               result: "b"
             })

    refute changeset.valid?
  end

  test "schema has no correlation_id field" do
    refute :correlation_id in AiOperation.__schema__(:fields)
    assert :run_stream_id in AiOperation.__schema__(:fields)
  end
end
