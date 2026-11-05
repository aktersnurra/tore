defmodule Tore.Capture.DispatchTest do
  use Tore.DataCase, async: false

  alias Tore.Capture.Dispatch
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run
  alias Tore.Harness.Run.State

  describe "set_plan_slot/2" do
    test "opens a child Run via Orchestrator and returns {bubble, child_sid}" do
      {:ok, recipe} =
        %Tore.Recipes.Recipe{title: "Carbonara", recipe_type: :meal}
        |> Tore.Repo.insert()

      {:ok, parent_sid} = Orchestrator.start_turn(%{household_id: 1, user_id: 42})

      ctx = %{
        household_id: 1,
        user_id: 42,
        parent_stream_id: parent_sid
      }

      assert {bubble, child_sid} =
               Dispatch.set_plan_slot(~D[2026-06-23], recipe.id, 4, ctx)

      assert bubble.role == :assistant
      assert bubble.text =~ "Carbonara"
      assert is_binary(child_sid)
      {:ok, %State.Applied{kind: "set_plan_slot_run"}} = Run.load(child_sid)
    end

    test "returns {error_bubble, nil} when recipe does not exist" do
      {:ok, parent_sid} = Orchestrator.start_turn(%{household_id: 1, user_id: 42})

      ctx = %{household_id: 1, user_id: 42, parent_stream_id: parent_sid}

      assert {bubble, nil} =
               Dispatch.set_plan_slot(~D[2026-06-23], 999_999, 4, ctx)

      assert bubble.role == :assistant
    end
  end

  test "a repeated photo links to review, not to a page that's gone" do
    household_id = Tore.Household.get_household!().id
    image = <<255, 216, 255, 1, 2, 3>>

    {:ok, _} =
      Tore.Capture.Uploads.record(
        household_id,
        Tore.Capture.Uploads.content_hash(image),
        "kr_seen",
        "receipt"
      )

    assert %{review_link: true, text: text} =
             Dispatch.ingest_receipt(image, %{household_id: household_id, user_id: nil})

    refute text =~ "inbox"
  end
end
