defmodule Tore.Capture.DispatchTest do
  use Tore.DataCase, async: false

  alias Tore.Capture.Dispatch
  alias Tore.Harness.Orchestrator
  alias Tore.Harness.Run
  alias Tore.Harness.Run.State

  describe "replies" do
    test "are in Swedish, with the day name in lower case mid-sentence" do
      Gettext.put_locale(ToreWeb.Gettext, "sv")

      {:ok, recipe} =
        %Tore.Recipes.Recipe{
          household_id: home_scope().household_id,
          title: "Carbonara",
          recipe_type: :meal
        }
        |> Tore.Repo.insert()

      {:ok, parent_sid} = Orchestrator.start_turn(%{household_id: 1, user_id: 42})
      ctx = %{household_id: 1, user_id: 42, parent_stream_id: parent_sid}

      assert {%{text: "La till Carbonara på måndag 2026-11-02."}, _child} =
               Dispatch.set_plan_slot(~D[2026-11-02], recipe.id, 4, ctx)

      assert %{text: "Hoppade över måndag 2026-11-02."} =
               Dispatch.skip_plan_meal(~D[2026-11-02], %{household_id: home_scope().household_id})
    end
  end

  describe "set_plan_slot/2" do
    test "opens a child Run via Orchestrator and returns {bubble, child_sid}" do
      {:ok, recipe} =
        %Tore.Recipes.Recipe{
          household_id: home_scope().household_id,
          title: "Carbonara",
          recipe_type: :meal
        }
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
      {:ok, %State.Applied{kind: "set_plan_slot_run"}} = Run.load(home_scope(), child_sid)
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
        Tore.Scope.for_household(household_id),
        Tore.Capture.Uploads.content_hash(image),
        "kr_seen",
        "receipt"
      )

    assert %{review_link: true, text: text} =
             Dispatch.ingest_receipt(image, %{household_id: household_id, user_id: nil})

    refute text =~ "inbox"
  end

  describe "mark_eating_out/3" do
    setup do
      user = user_fixture(name: "Tester")
      %{ctx: %{household_id: 1, user_id: user.id}}
    end

    test "marks the day, and a later call adds the amount", %{ctx: ctx} do
      date = ~D[2026-11-13]

      assert %{text: text} =
               Dispatch.mark_eating_out(date, %{description: "Sushi", total_amount: nil}, ctx)

      assert text =~ "2026-11-13"

      Dispatch.mark_eating_out(date, %{description: nil, total_amount: 450}, ctx)

      entry =
        Tore.Costs.get_dining_out(Tore.Streams.plan(home_scope(), ~D[2026-11-09]), "fri_dinner")

      assert entry.date == date
      assert entry.description == "Sushi"
      assert Decimal.equal?(entry.total_amount, 450)
    end
  end
end
