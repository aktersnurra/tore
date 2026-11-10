defmodule Tore.Harness.Kinds.HomePickTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.Costs
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.HomePick
  alias Tore.Harness.Kinds.HomePick, as: Kind

  setup :verify_on_exit!

  @tuesday_evening ~N[2026-11-10 17:00:00]
  @usage %{prompt_tokens: 120, completion_tokens: 0, cost_usd: 0.01}

  test "a sure answer is stored as the pick, and the call is recorded as home_pick" do
    expect(Tore.MockLLM, :decide, fn state, questions, opts ->
      assert Keyword.get(opts, :feature) == nil
      assert "It is Tuesday 2026-11-10, 17:00." in state
      assert %{"screen" => %{"type" => "choice"}} = questions

      {:ok,
       %{
         "screen" => %{"choice" => "plan", "confidence" => 0.9},
         "swap_open_shop" => %{"noul" => 0.8}
       }, @usage}
    end)

    assert {:ok, %KitchenRun{status: :applied, artifacts: [pick]} = run} =
             Runs.start(home_scope(), Kind, %{now: @tuesday_evening})

    assert %HomePick{screen: :plan, source: :model, swaps: [:open_shop]} = pick
    assert %KitchenRun{artifacts: [^pick]} = Runs.get(home_scope(), run.id)
    assert [{"home_pick", 1, 0.01}] = Costs.llm_calls_this_month_by_feature(home_scope())
  end

  test "a failed call stores the fixed rule's pick, so a stale one is still replaced" do
    expect(Tore.MockLLM, :decide, fn _state, _questions, _opts -> {:error, :timeout} end)

    assert {:ok,
            %KitchenRun{status: :applied, artifacts: [%HomePick{source: :rules, screen: :today}]}} =
             Runs.start(home_scope(), Kind, %{now: @tuesday_evening})
  end

  test "a household without AI gets no pick" do
    unsponsored = scope_fixture(household_fixture())

    assert {:error, {:step_failed, :ai_unavailable}} =
             Runs.start(unsponsored, Kind, %{now: @tuesday_evening})
  end

  test "verify refuses screens and swaps outside the lists, too many, repeated, or its own screen" do
    ok = %HomePick{screen: :shop, source: :model, swaps: [:open_plan]}
    assert :ok = Kind.verify(ok, %{})

    for bad <- [
          %{ok | screen: :settings},
          %{ok | swaps: [:open_plan, :open_today, :plan_next_week, :build_list]},
          %{ok | swaps: [:open_plan, :open_plan]},
          %{ok | swaps: [:open_shop]},
          %{ok | swaps: [:delete_everything]}
        ] do
      assert {:fail, :invalid_home_pick, :reject} = Kind.verify(bad, %{})
    end

    assert {:ok, %KitchenRun{status: :failed, failure_code: :invalid_home_pick}} =
             Runs.submit(home_scope(), Kind, %{ok | screen: :settings}, %{})
  end
end
