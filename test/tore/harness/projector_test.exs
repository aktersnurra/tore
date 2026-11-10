defmodule Tore.Harness.ProjectorTest do
  use Tore.DataCase, async: false
  alias Tore.Harness.{Projector, ProjectorSupervisor}
  alias Tore.Harness.Run
  alias Tore.Harness.Run.{Commands, State}

  setup do
    hh = household_fixture().id
    {:ok, pid} = ProjectorSupervisor.start_or_lookup(hh)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    %{hh: hh}
  end

  test "latest_on_surface/2 returns nil when no run has been opened", %{hh: hh} do
    assert Projector.latest_on_surface(hh, :plan) == nil
  end

  test "latest_on_surface/2 reflects a newly opened run after PubSub broadcast", %{hh: hh} do
    sid = Run.next_stream_id()

    {:ok, [ev]} =
      Run.decide(
        %Commands.Open{
          household_id: hh,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{command: "x"}
        },
        %State.Draft{stream_id: sid}
      )

    :ok = Run.append(Tore.Scope.for_household(hh), sid, [ev])

    # Wait briefly for the projector to handle the broadcast.
    Process.sleep(50)
    state = Projector.latest_on_surface(hh, :plan)
    assert %State.Running{stream_id: ^sid} = state
  end

  test "lookup/2 returns nil for an unknown stream_id", %{hh: hh} do
    assert Projector.lookup(hh, "run-unknown") == nil
  end

  test "projector boots by replaying open runs only" do
    other = household_fixture().id
    sid = Run.next_stream_id()

    {:ok, [ev]} =
      Run.decide(
        %Commands.Open{
          household_id: other,
          kind: "planner_command_run",
          surface: :plan,
          started_by: "user",
          user_id: 1,
          input: %{}
        },
        %State.Draft{stream_id: sid}
      )

    :ok = Run.append(Tore.Scope.for_household(other), sid, [ev])

    {:ok, _pid} = ProjectorSupervisor.start_or_lookup(other)
    Process.sleep(50)

    assert %State.Running{stream_id: ^sid} = Projector.latest_on_surface(other, :plan)
  end
end
