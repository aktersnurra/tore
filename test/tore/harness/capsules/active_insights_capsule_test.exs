defmodule Tore.Harness.Capsules.ActiveInsightsCapsuleTest do
  use Tore.DataCase, async: false

  alias Tore.Harness.Capsules.ActiveInsightsCapsule, as: Capsule

  @ctx %{household_id: 1, plan_stream_id: "plan:1:2026-06-08", week_start: ~D[2026-06-08]}

  test "build/1 collects active insight bodies" do
    {:ok, _} =
      Tore.Household.replace_insights([
        %{kind: "skip_pattern", body: "Mondays are often skipped.", confidence: 0.8, evidence: []}
      ])

    capsule = Capsule.build(@ctx)
    assert "Mondays are often skipped." in capsule.bodies
  end

  test "build/1 caps the bodies at 5" do
    insights =
      for n <- 1..8 do
        %{kind: "skip_pattern", body: "pattern #{n}", confidence: 0.5, evidence: []}
      end

    {:ok, _} = Tore.Household.replace_insights(insights)

    assert length(Capsule.build(@ctx).bodies) == 5
  end

  test "to_prompt/1 renders a bulleted patterns list" do
    {:ok, _} =
      Tore.Household.replace_insights([
        %{kind: "skip_pattern", body: "Mondays are often skipped.", confidence: 0.8, evidence: []}
      ])

    prompt = @ctx |> Capsule.build() |> Capsule.to_prompt()
    assert prompt =~ "Household patterns:"
    assert prompt =~ "- Mondays are often skipped."
  end

  test "to_prompt/1 is nil when there are no insights" do
    capsule = Capsule.build(@ctx)
    assert capsule.bodies == []
    assert Capsule.to_prompt(capsule) == nil
  end
end
