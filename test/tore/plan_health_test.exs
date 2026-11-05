defmodule Tore.PlanHealthTest do
  use ExUnit.Case, async: true
  alias Tore.PlanHealth

  defp make_state(assigned_days) do
    slots =
      assigned_days
      |> Enum.map(fn day -> {"#{day}_dinner", %{recipe_id: 1, skipped: false}} end)
      |> Map.new()

    %{slots: slots}
  end

  test "returns :unplanned when no slots assigned" do
    assert {:unplanned, 0} = PlanHealth.compute(%{slots: %{}})
  end

  test "returns :ready when all 5 weekday slots have recipes" do
    state = make_state(~w(mon tue wed thu fri))
    assert {:ready, 0} = PlanHealth.compute(state)
  end

  test "returns :flexible with the unplanned count when some weekday slots are unplanned" do
    state = make_state(~w(mon tue))
    assert {:flexible, 3} = PlanHealth.compute(state)
  end

  test "returns :fragile with the skipped count when a slot is skipped" do
    slots = %{
      "mon_dinner" => %{recipe_id: 1, skipped: false},
      "tue_dinner" => %{recipe_id: nil, skipped: true},
      "wed_dinner" => %{recipe_id: 2, skipped: false},
      "thu_dinner" => %{recipe_id: 3, skipped: false},
      "fri_dinner" => %{recipe_id: 4, skipped: false}
    }

    assert {:fragile, 1} = PlanHealth.compute(%{slots: slots})
  end

  defp eating_out, do: %{recipe_id: nil, skipped: true, reason: "eating_out"}

  test "eating out isn't a gap or a skip" do
    slots = make_state(~w(mon tue wed thu)).slots |> Map.put("fri_dinner", eating_out())
    assert {:ready, 0} = PlanHealth.compute(%{slots: slots})
  end

  test "eating out doesn't hide the days still unplanned" do
    slots = make_state(~w(mon)).slots |> Map.put("fri_dinner", eating_out())
    assert {:flexible, 3} = PlanHealth.compute(%{slots: slots})
  end

  test "a week with only eating out still counts as planned" do
    assert {:flexible, 4} = PlanHealth.compute(%{slots: %{"fri_dinner" => eating_out()}})
  end
end
