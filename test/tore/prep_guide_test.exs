defmodule Tore.PrepGuideTest do
  use ExUnit.Case, async: false

  import Tore.AccountsFixtures, only: [home_scope: 0]

  import Mox

  alias Tore.Prep

  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
    :ok
  end

  defp other_household do
    {:ok, household} = Tore.Household.create_household(%{name: "Other", locale: "sv"})
    household
  end

  defp plan_id, do: Tore.Streams.plan(home_scope(), ~D[2026-04-27])
  defp week_start, do: ~D[2026-04-27]

  defp mock_usage, do: %{prompt_tokens: 500, completion_tokens: 100, cost_usd: 0.0005}

  test "generate_guide calls LLM and persists prep guide" do
    Tore.MockLLM
    |> expect(:text, fn _system, _user, _opts ->
      {:ok,
       %{
         "timeline" => [
           %{"step" => 1, "task" => "Preheat oven", "duration_min" => 5, "component" => nil}
         ],
         "cascade_map" => %{"mon_dinner" => "Roast Chicken"},
         "storage_notes" => "Chicken: 3 days",
         "daily_assembly" => %{"mon_dinner" => "Plate and serve"},
         "prep_session" => %{
           "proteins" => ["chicken"],
           "bases" => [],
           "sauces" => [],
           "vegetables" => []
         }
       }, mock_usage()}
    end)

    assert {:ok, guide} = Prep.generate_guide(home_scope(), plan_id(), week_start())
    assert guide.week_start == week_start()
    assert length(guide.timeline) == 1
    assert guide.storage_notes == "Chicken: 3 days"
    assert Prep.get_guide_for_week(home_scope(), week_start()).id == guide.id

    assert Prep.get_guide_for_week(Tore.Scope.for_household(other_household().id), week_start()) ==
             nil
  end

  test "generate_guide returns error when LLM fails" do
    Tore.MockLLM |> expect(:text, fn _system, _user, _opts -> {:error, :timeout} end)
    assert {:error, :timeout} = Prep.generate_guide(home_scope(), plan_id(), week_start())
  end

  test "generate_guide returns budget_exceeded when over limit" do
    Tore.Costs.log_llm_usage(%{
      feature: "seed",
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd: 20.0
    })

    assert {:error, :budget_exceeded} = Prep.generate_guide(home_scope(), plan_id(), week_start())
  end
end
