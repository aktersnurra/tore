defmodule Tore.Capture.RouterTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Capture.Router
  alias Tore.Harness.{KitchenRun, Runs}

  describe "route/4 with set_plan_slot" do
    test "sets the slot through a run the reply can undo" do
      {:ok, recipe} =
        %Tore.Recipes.Recipe{
          household_id: home_scope().household_id,
          title: "Pizza",
          recipe_type: :meal
        }
        |> Tore.Repo.insert()

      # Turn 1: model emits a set_plan_slot tool call.
      # Turn 2: model replies in plain text.
      tool_call = %{
        id: "call_1",
        name: "set_plan_slot",
        args: %{"date" => "2026-06-23", "recipe_id" => recipe.id, "servings" => 4}
      }

      expect(Tore.MockLLM, :chat_with_tools, 2, fn _sys, _msgs, _tools, _opts ->
        case Process.get(:turn_count, 0) do
          0 ->
            Process.put(:turn_count, 1)

            {:ok, {:tool_calls, [tool_call]},
             %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}

          _ ->
            {:ok, {:message, "Done."},
             %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}}
        end
      end)

      ctx = %{household_id: 1, user_id: user_fixture().id, locale: "en"}
      assert {:ok, bubbles} = Router.route("plan pizza tuesday", [], ctx)

      # The user-facing bubbles still flow through.
      assert Enum.any?(bubbles, fn b -> Map.get(b, :text) =~ "Pizza" end)

      # The slot was set through its own run, which the bubble's Undo reverts.
      %{run_stream_id: id} = Enum.find(bubbles, &Map.has_key?(&1, :run_stream_id))
      assert %KitchenRun{status: :applied, kind: "set_plan_slot_run"} = Runs.get(home_scope(), id)
    end
  end

  describe "route/4 with mark_eating_out" do
    test "marks the day through Capture, even an empty one" do
      user = user_fixture(name: "Tester")

      tool_call = %{
        id: "call_1",
        name: "mark_eating_out",
        args: %{"date" => "2026-11-13", "place" => "Sushi", "amount" => 450}
      }

      usage = %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}

      Tore.MockLLM
      |> expect(:chat_with_tools, fn _sys, _msgs, tools, _opts ->
        assert Enum.any?(tools, &(&1.function.name == "mark_eating_out"))
        {:ok, {:tool_calls, [tool_call]}, usage}
      end)
      |> expect(:chat_with_tools, fn _sys, _msgs, _tools, _opts ->
        {:ok, {:message, "Done."}, usage}
      end)

      ctx = %{household_id: 1, user_id: user.id}
      assert {:ok, _bubbles} = Router.route("vi äter ute på fredag", [], ctx)

      {:ok, state} =
        Tore.Planning.load_plan(home_scope(), Tore.Streams.plan(home_scope(), ~D[2026-11-09]))

      assert %{place: "Sushi", amount: "450"} = state.slots["fri_dinner"]
      assert Tore.Planning.State.eating_out?(state.slots["fri_dinner"])
    end
  end
end
