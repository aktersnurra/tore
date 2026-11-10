defmodule Tore.RunFixtures do
  @moduledoc "Runs with a stored photo, for tests of the files that belong to a run."

  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Commands, Decider, State}
  alias Tore.Storage.RunPhotos

  @doc "An open run in the scope's household whose input holds a stored photo. Returns `{stream_id, key}`."
  def run_with_photo_fixture(scope, bytes \\ "photo bytes") do
    sid = Run.next_stream_id()
    {:ok, key} = RunPhotos.store(scope, sid, bytes)

    {:ok, events} =
      Decider.decide(
        %Commands.Open{
          household_id: scope.household_id,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: nil,
          input: %{image_path: key}
        },
        %State.Draft{stream_id: sid}
      )

    :ok = Run.append(scope, sid, events)
    {sid, key}
  end

  @doc "Records a failure on the run, which makes it finished."
  def fail_run(scope, sid) do
    {:ok, state} = Run.load(scope, sid)
    {:ok, events} = Decider.decide(%Commands.RecordFailure{code: :llm_error}, state)
    :ok = Run.append(scope, sid, events)
  end
end
