defmodule Tore.LLMGateTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Costs, LLM, Repo}

  setup :verify_on_exit!

  @usage %{prompt_tokens: 3, completion_tokens: 2, cost_usd: 0.25}

  defp expect_text(times \\ 1) do
    expect(Tore.MockLLM, :text, times, fn "sys", "user", opts ->
      refute Keyword.has_key?(opts, :feature)
      {:ok, %{"ok" => true}, @usage}
    end)
  end

  test "a partner in a sponsored household can use it, and the call is recorded for the household" do
    partner = scope_fixture(user_fixture())
    expect_text()

    assert {:ok, %{"ok" => true}, _} = LLM.text(partner, "sys", "user", feature: :cook_mode)

    assert [{"cook_mode", 1, 0.25}] = Costs.llm_calls_this_month_by_feature(home_scope())
  end

  test "a household nobody sponsors makes no call" do
    unsponsored = scope_fixture(household_fixture())

    refute LLM.available?(unsponsored)
    assert {:error, :ai_unavailable} = LLM.text(unsponsored, "sys", "user")
    assert Costs.llm_spend_total(unsponsored) == 0.0
  end

  test "without a key no household can use it" do
    previous = Application.get_env(:tore, :openrouter_api_key)
    Application.delete_env(:tore, :openrouter_api_key)
    on_exit(fn -> Application.put_env(:tore, :openrouter_api_key, previous) end)

    refute LLM.available?(home_scope())
    assert {:error, :ai_unavailable} = LLM.text(home_scope(), "sys", "user")
  end

  test "a household that has spent its monthly limit makes no call" do
    {:ok, _} =
      Costs.log_llm_usage(home_scope(), %{feature: "seed", cost_usd: LLM.monthly_limit_usd()})

    assert {:error, :budget_exceeded} = LLM.text(home_scope(), "sys", "user")
  end

  test "one household's spend doesn't count against another's limit" do
    other = scope_fixture(household_fixture())
    {:ok, _} = Costs.log_llm_usage(other, %{feature: "seed", cost_usd: LLM.monthly_limit_usd()})
    expect_text()

    assert {:ok, _, _} = LLM.text(home_scope(), "sys", "user")
    assert Costs.llm_spend_this_month(home_scope()) == 0.25
  end

  test "a sponsor who loses the credits claim stops the household's AI" do
    sponsor = Repo.get!(Tore.Household.HouseholdSchema, 1).ai_sponsor_id

    Repo.update_all(from(u in Tore.Accounts.User, where: u.id == ^sponsor),
      set: [ai_enabled: false]
    )

    assert {:error, :ai_unavailable} = LLM.text(home_scope(), "sys", "user")
  end
end
