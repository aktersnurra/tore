defmodule Tore.LLM.PlannerToolsWebTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.LLM.PlannerTools
  alias Tore.Planning.State

  @plan %State{}
  @ctx %{plan_id: "plan-1", week_start: ~D[2026-06-01], household_id: 1}

  defp tool(name), do: Enum.find(PlannerTools.all(), &(&1.name == name))

  test "find_recipe_web is a read tool in the catalog" do
    assert %{kind: :read} = tool("find_recipe_web")
  end

  test "find_recipe_web returns candidate titles and urls" do
    expect(Tore.MockLLM, :web_search, fn _system, _user, _opts ->
      {:ok,
       %{
         "candidates" => [
           %{"title" => "Best Miso Ramen", "url" => "https://example.com/ramen"},
           %{"title" => "Quick Ramen", "url" => "https://example.com/quick"}
         ]
       }, %{prompt_tokens: 10, completion_tokens: 5, cost_usd: 0.001}}
    end)

    assert {:ok, result, [], @plan} =
             tool("find_recipe_web").run.(%{"query" => "miso ramen"}, @ctx, @plan)

    assert result.candidates == [
             %{title: "Best Miso Ramen", url: "https://example.com/ramen"},
             %{title: "Quick Ramen", url: "https://example.com/quick"}
           ]
  end

  test "find_recipe_web reports no matches without erroring" do
    expect(Tore.MockLLM, :web_search, fn _, _, _ ->
      {:ok, %{"candidates" => []}, %{prompt_tokens: 1, completion_tokens: 1, cost_usd: 0.0}}
    end)

    assert {:ok, %{candidates: [], not_found: true}, [], @plan} =
             tool("find_recipe_web").run.(%{"query" => "unobtainium stew"}, @ctx, @plan)
  end

  test "find_recipe_web returns a resting message when SpendGuard blocks it" do
    # Burn the cooldown by logging a call for the feature right now. cost_usd
    # is a float column — a Decimal fails the cast and the row never lands.
    {:ok, _} =
      Tore.Costs.log_llm_usage(home_scope(), %{
        feature: "recipe_web_search",
        prompt_tokens: 1,
        completion_tokens: 1,
        cost_usd: 0.0001
      })

    assert {:ok, %{unavailable: true} = result, [], @plan} =
             tool("find_recipe_web").run.(%{"query" => "ramen"}, @ctx, @plan)

    assert result.reason =~ "resting"
  end

  test "find_recipe_web surfaces an LLM error as a tool error" do
    expect(Tore.MockLLM, :web_search, fn _, _, _ -> {:error, :timeout} end)

    assert {:error, :timeout} = tool("find_recipe_web").run.(%{"query" => "ramen"}, @ctx, @plan)
  end

  test "the tool declares a required query parameter" do
    assert tool("find_recipe_web").parameters.required == ["query"]
  end
end
