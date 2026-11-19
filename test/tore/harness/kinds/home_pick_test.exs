defmodule Tore.Harness.Kinds.HomePickTest do
  use Tore.DataCase, async: false

  import Ecto.Query

  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.HomePick
  alias Tore.Harness.Kinds.HomePick, as: Kind

  defp set(args) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "set_home_pick", "arguments" => args}
    }

    {:reply, %{"result" => result}} = Tore.Mcp.handle(home_scope(), request)
    result
  end

  test "set_home_pick stores pi's pick, and Home reads it" do
    assert %{"isError" => false} = set(%{"screen" => "plan", "swaps" => ["open_shop"]})

    assert %KitchenRun{actor: :mcp, artifacts: [pick]} =
             Repo.one(from(r in KitchenRun, where: r.kind == "home_pick_run"), household_id: 1)

    assert %HomePick{screen: :plan, source: :model, swaps: [:open_shop], note: nil} = pick
  end

  test "set_home_pick keeps the note pi chose for Today" do
    assert %{"isError" => false} =
             set(%{"screen" => "today", "swaps" => [], "note" => "buy_for_tomorrow"})

    assert %KitchenRun{artifacts: [%HomePick{note: :buy_for_tomorrow}]} =
             Repo.one(from(r in KitchenRun, where: r.kind == "home_pick_run"), household_id: 1)
  end

  test "a pick outside the lists, or swapping to its own screen, is refused" do
    assert %{"isError" => true} = set(%{"screen" => "settings", "swaps" => []})
    assert %{"isError" => true} = set(%{"screen" => "plan", "swaps" => ["dance"]})
    assert %{"isError" => true} = set(%{"screen" => "plan", "swaps" => ["open_plan"]})

    assert %{"isError" => true} =
             set(%{"screen" => "plan", "swaps" => [], "note" => "say_something"})

    refute Repo.exists?(from(r in KitchenRun, where: r.status == :applied), household_id: 1)
  end

  test "verify refuses screens and swaps outside the lists, too many, repeated, or its own screen" do
    ok = %HomePick{screen: :shop, source: :model, swaps: [:open_plan]}
    assert :ok = Kind.verify(ok, %{})

    for bad <- [
          %{ok | screen: :settings},
          %{ok | swaps: [:open_plan, :open_today, :plan_next_week, :build_list]},
          %{ok | swaps: [:open_plan, :open_plan]},
          %{ok | swaps: [:open_shop]},
          %{ok | swaps: [:delete_everything]}
        ] do
      assert {:fail, :invalid_home_pick, :reject} = Kind.verify(bad, %{})
    end

    assert {:ok, %KitchenRun{status: :failed, failure_code: :invalid_home_pick}} =
             Runs.submit(home_scope(), Kind, %{ok | screen: :settings}, %{})
  end
end
