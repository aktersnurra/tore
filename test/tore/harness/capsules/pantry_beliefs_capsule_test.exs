defmodule Tore.Harness.Capsules.PantryBeliefsCapsuleTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Capsules.PantryBeliefsCapsule, as: Capsule

  @ctx %{household_id: 1, plan_stream_id: "plan:2026-06-08", week_start: ~D[2026-06-08]}

  test "build/1 caps names at 20 but keeps the full total" do
    for n <- 1..25, do: Tore.Pantry.add_item(%{name: "item #{n}", quantity: 1})

    capsule = Capsule.build(@ctx)
    assert length(capsule.names) == 20
    assert capsule.total == 25
  end

  test "to_prompt/1 lists names and the overflow count" do
    for n <- 1..25, do: Tore.Pantry.add_item(%{name: "item #{n}", quantity: 1})

    prompt = @ctx |> Capsule.build() |> Capsule.to_prompt()
    assert prompt =~ "Pantry has:"
    assert prompt =~ "and 5 more"
    assert String.ends_with?(prompt, ".")
  end

  test "to_prompt/1 has no overflow clause at or below 20 items" do
    for n <- 1..3, do: Tore.Pantry.add_item(%{name: "item #{n}", quantity: 1})

    prompt = @ctx |> Capsule.build() |> Capsule.to_prompt()
    assert prompt =~ "Pantry has:"
    refute prompt =~ "more"
  end

  test "to_prompt/1 is nil for an empty pantry" do
    capsule = Capsule.build(@ctx)
    assert capsule.names == []
    assert capsule.total == 0
    assert Capsule.to_prompt(capsule) == nil
  end

  test "items that need using soon come first and are called out" do
    for n <- 1..25, do: Tore.Pantry.add_item(%{name: "item #{n}", quantity: 1})
    {:ok, _} = Tore.Pantry.add_item(%{name: "öl", expires_at: Date.add(Date.utc_today(), 90)})
    {:ok, _} = Tore.Pantry.add_item(%{name: "ägg", expires_at: Date.add(Date.utc_today(), 3)})
    {:ok, _} = Tore.Pantry.add_item(%{name: "ål", expires_at: Date.utc_today()})

    capsule = Capsule.build(@ctx)

    assert Enum.take(capsule.names, 2) == ["ål", "ägg"]
    assert capsule.use_soon == ["ål", "ägg"]
    assert Capsule.to_prompt(capsule) =~ "Use soon: ål, ägg."
  end

  test "items past their date aren't in the pantry" do
    {:ok, _} = Tore.Pantry.add_item(%{name: "gammal", expires_at: Date.add(Date.utc_today(), -1)})

    assert Capsule.build(@ctx) |> Capsule.to_prompt() == nil
  end
end
