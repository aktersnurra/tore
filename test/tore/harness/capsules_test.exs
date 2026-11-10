defmodule Tore.Harness.CapsulesTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Capsules

  alias Tore.Harness.Capsules.{
    HouseholdPreferencesCapsule,
    MemoryCapsule,
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

    # no memory → MemoryCapsule renders nil and is dropped

    prompt =
      Capsules.compose([HouseholdPreferencesCapsule, MemoryCapsule], ctx())

    assert prompt =~ "Household preferences:"
    refute prompt =~ "HOUSEHOLD PROFILE"
  end

  test "compose/2 returns an empty string when every capsule renders nil" do
    # nothing seeded: no prefs, no memory, no pantry → all nil
    prompt =
      Capsules.compose(
        [HouseholdPreferencesCapsule, MemoryCapsule, PantryBeliefsCapsule],
        ctx()
      )

    assert prompt == ""
  end

  test "compose/2 separates two rendered capsules with a blank line" do
    {:ok, _} =
      Tore.Household.update_preferences(home_scope(), %{dietary_restrictions: ["vegetarian"]})

    run =
      home_scope()
      |> Tore.Harness.KitchenRun.open(
        %{kind: "memory_review_run", actor: :system, input: %{}},
        DateTime.utc_now()
      )
      |> Tore.Repo.insert!()

    Tore.Repo.insert!(%Tore.Household.Memory{
      household_id: home_scope().household_id,
      store: "notes",
      text: "Mondays are often skipped.",
      run_id: run.id
    })

    prompt =
      Capsules.compose([HouseholdPreferencesCapsule, MemoryCapsule], ctx())

    assert prompt =~ "Household preferences:"
    assert prompt =~ "Mondays are often skipped."
    assert prompt =~ "\n\n"
  end
end
