defmodule Tore.PrepGuideTest do
  @moduledoc "The week's prep guide: written by pi as a job, saved with save_prep_guide."
  use Tore.DataCase, async: false

  import Tore.FakePi

  alias Tore.{Mcp, Prep}

  defp save(scope, args) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "save_prep_guide", "arguments" => args}
    }

    {:reply, %{"result" => result}} = Mcp.handle(scope, request)
    result
  end

  @guide %{
    "week" => "2026-04-29",
    "prep_session" => %{"proteins" => ["hel kyckling — ugn 200°C 60 min"]},
    "timeline" => [%{"task" => "Sätt ugnen på 200°C", "duration_min" => 5}],
    "storage_notes" => "Kyckling: kyl 3 dagar.",
    "daily_assembly" => %{"2026-04-27" => "Lägg upp kycklingen med grönsakerna"}
  }

  test "save_prep_guide saves the guide for the week of the day it names, one per week" do
    Phoenix.PubSub.subscribe(Tore.PubSub, Prep.topic(home_scope()))

    assert %{"isError" => false} = save(home_scope(), @guide)
    assert_received {:prep_guide_saved, %{week_start: ~D[2026-04-27]}}

    guide = Prep.get_guide_for_week(home_scope(), ~D[2026-04-27])
    assert [%{"task" => "Sätt ugnen på 200°C"}] = guide.timeline
    assert guide.prep_session["proteins"] == ["hel kyckling — ugn 200°C 60 min"]

    again = put_in(@guide["timeline"], [%{"task" => "Koka riset", "duration_min" => 20}])
    assert %{"isError" => false} = save(home_scope(), again)

    assert [%{"task" => "Koka riset"}] =
             Prep.get_guide_for_week(home_scope(), ~D[2026-04-27]).timeline

    {:ok, other} = Tore.Household.create_household(%{name: "Other", locale: "sv"})
    assert Prep.get_guide_for_week(Tore.Scope.for_household(other.id), ~D[2026-04-27]) == nil
  end

  test "a guide without a week is refused" do
    assert %{"isError" => true} = save(home_scope(), Map.delete(@guide, "week"))
  end

  describe "start/2" do
    setup :fake_pi

    test "asks pi for the week's guide as a background job", %{pi_log: log} do
      assert :ok = Prep.start(home_scope(), ~D[2026-04-27])

      prompt = Enum.find(pi_records(log), &(&1["type"] == "prompt"))["message"]
      assert prompt =~ "Background job: prep_guide."
      assert prompt =~ "Week starting 2026-04-27."
    end
  end

  test "start/2 says so when there is no pi" do
    assert {:error, :pi_off} = Prep.start(home_scope(), ~D[2026-04-27])
  end
end
