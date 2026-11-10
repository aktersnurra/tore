defmodule Tore.Harness.CapsulesTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Capsules

  alias Tore.Harness.Capsules.{
    HouseholdPreferencesCapsule,
    ActiveInsightsCapsule,
    PantryBeliefsCapsule
  }

  defp ctx do
    scope = home_scope()

    %{
      household_id: scope.household_id,
      plan_stream_id: Tore.Streams.plan(scope, ~D[2026-06-08]),
      week_start: ~D[2026-06-08]
    }
  end

  test "compose/2 joins rendered capsules and drops nils, preserving order" do
    {:ok, _} =
      Tore.Household.update_preferences(home_scope(), %{dietary_restrictions: ["vegetarian"]})

    # no insights seeded → ActiveInsightsCapsule renders nil and is dropped

    prompt =
      Capsules.compose([HouseholdPreferencesCapsule, ActiveInsightsCapsule], ctx())

    assert prompt =~ "Household preferences:"
    refute prompt =~ "Household patterns:"
  end

  test "compose/2 returns an empty string when every capsule renders nil" do
    # nothing seeded: no prefs, no insights, no pantry → all nil
    prompt =
      Capsules.compose(
        [HouseholdPreferencesCapsule, ActiveInsightsCapsule, PantryBeliefsCapsule],
        ctx()
      )

    assert prompt == ""
  end

  test "compose/2 separates two rendered capsules with a blank line" do
    {:ok, _} =
      Tore.Household.update_preferences(home_scope(), %{dietary_restrictions: ["vegetarian"]})

    {:ok, _} =
      Tore.Household.replace_insights(home_scope(), [
        %{kind: "skip_pattern", body: "Mondays are often skipped.", confidence: 0.8, evidence: []}
      ])

    prompt =
      Capsules.compose([HouseholdPreferencesCapsule, ActiveInsightsCapsule], ctx())

    assert prompt =~ "Household preferences:"
    assert prompt =~ "Household patterns:"
    assert prompt =~ "\n\n"
  end
end
