defmodule Tore.Harness.Capsules.HouseholdPreferencesCapsuleTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Capsules.HouseholdPreferencesCapsule, as: Capsule

  defp ctx do
    scope = home_scope()

    %{
      household_id: scope.household_id,
      plan_stream_id: Tore.Streams.plan(scope, ~D[2026-06-08]),
      week_start: ~D[2026-06-08]
    }
  end

  test "build/1 captures the dietary guidance string" do
    {:ok, _} =
      Tore.Household.update_preferences(home_scope(), %{dietary_restrictions: ["vegetarian"]})

    capsule = Capsule.build(ctx())
    assert is_binary(capsule.guidance)
    assert capsule.guidance =~ "vegetarian" or capsule.guidance =~ "Vegetarian"
  end

  test "to_prompt/1 renders the guidance into the household-preferences line" do
    {:ok, _} =
      Tore.Household.update_preferences(home_scope(), %{dietary_restrictions: ["vegetarian"]})

    prompt = ctx() |> Capsule.build() |> Capsule.to_prompt()
    assert prompt =~ "Household preferences:"
    assert String.ends_with?(prompt, ".")
  end

  test "to_prompt/1 is nil when there is no guidance" do
    capsule = Capsule.build(ctx())
    assert capsule.guidance == nil
    assert Capsule.to_prompt(capsule) == nil
  end
end
