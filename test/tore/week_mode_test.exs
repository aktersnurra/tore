defmodule Tore.WeekModeTest do
  use Tore.DataCase, async: false
  alias Tore.WeekMode

  test "get_current_mode/0 returns 'normal' when nothing set" do
    assert WeekMode.get_current_mode(home_scope()) == "normal"
  end

  test "set_mode/1 and get_current_mode/0 round-trip" do
    {:ok, _} = WeekMode.set_mode(home_scope(), "low_effort")
    assert WeekMode.get_current_mode(home_scope()) == "low_effort"
  end

  test "set_mode/1 twice overwrites — only one record per week" do
    {:ok, _} = WeekMode.set_mode(home_scope(), "low_effort")
    {:ok, _} = WeekMode.set_mode(home_scope(), "budget_week")
    assert WeekMode.get_current_mode(home_scope()) == "budget_week"
  end

  test "set_mode/1 with invalid mode returns error" do
    assert {:error, changeset} = WeekMode.set_mode(home_scope(), "turbo_cook")
    assert changeset.errors[:mode]
  end

  test "mode_prompt_fragment/1 returns nil for normal" do
    assert WeekMode.mode_prompt_fragment("normal") == nil
  end

  test "mode_prompt_fragment/1 returns non-nil string for low_effort" do
    fragment = WeekMode.mode_prompt_fragment("low_effort")
    assert is_binary(fragment)
    assert String.contains?(fragment, "Low effort")
  end

  test "each household has its own week mode" do
    other = scope_fixture(household_fixture())
    {:ok, _} = WeekMode.set_mode(home_scope(), "low_effort")

    assert WeekMode.get_current_mode(other) == "normal"
    {:ok, _} = WeekMode.set_mode(other, "budget_week")
    assert WeekMode.get_current_mode(home_scope()) == "low_effort"
  end
end
