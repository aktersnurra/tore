defmodule Tore.HouseholdTest do
  # Not async: these write the singleton household/preferences row, which has no
  # per-test isolation key, so running concurrently with other writers deadlocks
  # SQLite's single write lock (raises `Database busy`). Serialize this module.
  use Tore.DataCase, async: false
  alias Tore.Household

  test "get!/1 returns the scope's household" do
    other = household_fixture(%{name: "Andra"})

    assert Household.get!(home_scope()).name == "Home"
    assert Household.get!(scope_fixture(other)).name == "Andra"
  end

  test "each household has its own preferences" do
    other = scope_fixture(household_fixture())
    {:ok, _} = Household.update_preferences(home_scope(), %{dietary_restrictions: ["vegetarian"]})

    assert Household.get_preferences(other).dietary_restrictions == []
    {:ok, _} = Household.update_preferences(other, %{allergies: ["nuts"]})
    assert Household.get_preferences(home_scope()).dietary_restrictions == ["vegetarian"]
    assert Household.get_preferences(home_scope()).allergies == []
  end

  test "each_scope/1 runs every household even when one fails" do
    other = household_fixture()
    home_id = home_scope().household_id

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 Household.each_scope(fn scope ->
                   if scope.household_id == home_id, do: raise("boom")
                   send(self(), {:ran, scope.household_id})
                 end)
      end)

    assert_received {:ran, id} when id == other.id
    refute_received {:ran, ^home_id}
    assert log =~ "job failed for household #{home_id}"
  end

  test "create_household/1 inserts a household" do
    assert {:ok, household} = Household.create_household(%{name: "Rydholm", locale: "sv"})
    assert household.name == "Rydholm"
  end

  test "create_household/1 rejects invalid locale" do
    assert {:error, cs} = Household.create_household(%{name: "Test", locale: "zz"})
    assert cs.errors[:locale]
  end

  describe "preferences" do
    test "get_preferences/0 returns empty preferences struct when none exist" do
      prefs = Household.get_preferences(home_scope())
      assert prefs.allergies == []
      assert prefs.dietary_restrictions == []
    end

    test "update_preferences/1 persists and returns updated preferences" do
      assert {:ok, prefs} =
               Household.update_preferences(home_scope(), %{
                 allergies: ["nuts"],
                 dietary_restrictions: ["vegan"]
               })

      assert prefs.allergies == ["nuts"]
      assert prefs.dietary_restrictions == ["vegan"]
    end

    test "update_preferences/1 is idempotent — second update replaces first" do
      {:ok, _} = Household.update_preferences(home_scope(), %{allergies: ["nuts"]})
      assert {:ok, prefs} = Household.update_preferences(home_scope(), %{allergies: ["eggs"]})
      assert prefs.allergies == ["eggs"]
    end

    test "prefs_to_dietary_guidance/1 returns nil for empty prefs" do
      prefs = Household.get_preferences(home_scope())
      assert Household.prefs_to_dietary_guidance(prefs) == nil
    end

    test "prefs_to_dietary_guidance/1 formats dietary restrictions" do
      {:ok, prefs} =
        Household.update_preferences(home_scope(), %{
          dietary_restrictions: ["vegetarian"],
          allergies: ["nuts"]
        })

      guidance = Household.prefs_to_dietary_guidance(prefs)
      assert guidance =~ "Diet: vegetarian"
      assert guidance =~ "Allergies/hard avoids: nuts"
    end
  end
end
