defmodule Tore.HouseholdInsightsTest do
  use Tore.DataCase, async: false

  alias Tore.Household

  defp insight_attrs(overrides \\ %{}) do
    Map.merge(
      %{kind: "skip_pattern", body: "Household skips Mondays", confidence: 0.8},
      overrides
    )
  end

  test "list_active_insights returns only active insights sorted by confidence desc" do
    {:ok, _} = Household.replace_insights(home_scope(), [insight_attrs(%{confidence: 0.6})])

    {:ok, _} =
      Household.replace_insights(home_scope(), [
        insight_attrs(%{confidence: 0.9, body: "High confidence"}),
        insight_attrs(%{confidence: 0.4, body: "Low confidence"})
      ])

    active = Household.list_active_insights(home_scope())
    assert length(active) == 2
    assert hd(active).confidence == 0.9
    assert Enum.all?(active, &(&1.status == "active"))
  end

  test "replace_insights supersedes previous active insights" do
    {:ok, first_batch} = Household.replace_insights(home_scope(), [insight_attrs()])
    first_id = hd(first_batch).id

    {:ok, _} = Household.replace_insights(home_scope(), [insight_attrs(%{body: "New insight"})])

    old =
      Tore.Repo.get!(
        Tore.Household.HouseholdInsight,
        first_id,
        Tore.Scope.repo_opts(home_scope())
      )

    assert old.status == "superseded"
  end

  test "dismiss_insight marks insight as dismissed" do
    {:ok, [insight]} = Household.replace_insights(home_scope(), [insight_attrs()])

    {:ok, dismissed} = Household.dismiss_insight(home_scope(), insight.id)
    assert dismissed.status == "dismissed"
    assert Household.list_active_insights(home_scope()) == []
  end

  test "list_active_insights excludes dismissed insights" do
    {:ok, [insight]} = Household.replace_insights(home_scope(), [insight_attrs()])
    Household.dismiss_insight(home_scope(), insight.id)

    assert Household.list_active_insights(home_scope()) == []
  end

  test "insights belong to their household" do
    other = scope_fixture(household_fixture())
    {:ok, [theirs]} = Household.replace_insights(other, [insight_attrs()])
    {:ok, _} = Household.replace_insights(home_scope(), [insight_attrs(%{body: "Ours"})])

    assert Enum.map(Household.list_active_insights(other), & &1.id) == [theirs.id]
    assert_raise Ecto.NoResultsError, fn -> Household.dismiss_insight(home_scope(), theirs.id) end
  end
end
