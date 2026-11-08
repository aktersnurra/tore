defmodule Tore.SpendGuardTest do
  use ExUnit.Case, async: false

  import Tore.AccountsFixtures, only: [home_scope: 0, household_fixture: 0, scope_fixture: 1]

  alias Tore.SpendGuard

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
  end

  test "allow? returns :ok when under budget" do
    assert :ok = SpendGuard.allow?(home_scope(), :generate_prep_guide)
  end

  test "allow? returns budget_exceeded when over monthly limit" do
    Tore.Costs.log_llm_usage(home_scope(), %{
      feature: "seed",
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd: 20.0
    })

    assert {:error, :budget_exceeded} = SpendGuard.allow?(home_scope(), :generate_prep_guide)
  end

  test "allow? returns cooldown when same feature called within 60s" do
    Tore.Costs.log_llm_usage(home_scope(), %{
      feature: "generate_prep_guide",
      prompt_tokens: 100,
      completion_tokens: 50,
      cost_usd: 0.001
    })

    assert {:error, :cooldown} = SpendGuard.allow?(home_scope(), :generate_prep_guide)
  end

  test "allow? does not apply cooldown across different features" do
    Tore.Costs.log_llm_usage(home_scope(), %{
      feature: "suggest_recipe",
      prompt_tokens: 100,
      completion_tokens: 50,
      cost_usd: 0.001
    })

    assert :ok = SpendGuard.allow?(home_scope(), :generate_prep_guide)
  end

  test "another household's spend and calls don't count" do
    other = scope_fixture(household_fixture())

    Tore.Costs.log_llm_usage(other, %{
      feature: "generate_prep_guide",
      prompt_tokens: 0,
      completion_tokens: 0,
      cost_usd: 20.0
    })

    assert :ok = SpendGuard.allow?(home_scope(), :generate_prep_guide)
  end
end
