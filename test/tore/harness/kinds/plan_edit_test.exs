defmodule Tore.Harness.Kinds.PlanEditTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Costs, Planning, Recipes}
  alias Tore.Capture.Dispatch
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.PlanDiff
  alias Tore.Planning.State

  setup :verify_on_exit!

  # A Monday, so the dates below fall in one week.
  @monday ~D[2026-06-08]

  setup do
    stub(Tore.MockHTTP, :fetch, fn _url -> {:error, :not_found} end)
    user = user_fixture()
    plan = Tore.Streams.plan(home_scope(), @monday)

    {:ok, stew} =
      Recipes.create(home_scope(), %{
        title: "Stew",
        base_servings: 4,
        image_url: "https://x/y.jpg"
      })

    {:ok, _} = Planning.assign_recipe(home_scope(), plan, "mon_dinner", stew.id, 4)
    %{ctx: %{household_id: home_scope().household_id, user_id: user.id}, plan: plan, stew: stew}
  end

  defp plan(plan) do
    {:ok, state} = Planning.load_plan(home_scope(), plan)
    state
  end

  defp run(%{run_stream_id: id}), do: Runs.get(home_scope(), id)
  defp undo(%{run_stream_id: id}), do: {:ok, _} = Runs.revert(home_scope(), id)

  test "clearing a day applies with undo, and undo puts the recipe back", ctx do
    bubble = Dispatch.clear_plan_slot(@monday, ctx.ctx)

    assert %KitchenRun{status: :applied, kind: "plan_edit_run", surface: :plan} = run(bubble)
    refute Map.has_key?(plan(ctx.plan).slots, "mon_dinner")

    undo(bubble)
    assert plan(ctx.plan).slots["mon_dinner"].recipe_id == ctx.stew.id
  end

  test "servings and skips undo too", ctx do
    servings = Dispatch.set_plan_servings(@monday, 6, ctx.ctx)
    assert plan(ctx.plan).slots["mon_dinner"].servings == 6

    skip = Dispatch.skip_plan_meal(@monday, ctx.ctx)
    assert plan(ctx.plan).slots["mon_dinner"].skipped

    undo(skip)
    undo(servings)
    assert %{servings: 4, skipped: false} = plan(ctx.plan).slots["mon_dinner"]
  end

  test "a pinned day is left as it was, but can be unpinned", ctx do
    pin = Dispatch.pin_plan_slot(@monday, true, ctx.ctx)
    assert Map.has_key?(plan(ctx.plan).pins, "mon_dinner")

    Gettext.put_locale(ToreWeb.Gettext, "sv")
    bubble = Dispatch.clear_plan_slot(@monday, ctx.ctx)
    assert bubble.text =~ "fastlåst"
    refute Map.has_key?(bubble, :run_stream_id)
    assert plan(ctx.plan).slots["mon_dinner"].recipe_id == ctx.stew.id

    unpin = Dispatch.pin_plan_slot(@monday, false, ctx.ctx)
    refute Map.has_key?(plan(ctx.plan).pins, "mon_dinner")

    undo(unpin)
    assert Map.has_key?(plan(ctx.plan).pins, "mon_dinner")
    undo(pin)
    refute Map.has_key?(plan(ctx.plan).pins, "mon_dinner")
  end

  test "eating out writes its cost, and undo takes both back", ctx do
    bubble =
      Dispatch.mark_eating_out(@monday, %{description: "Sushi", total_amount: 450}, ctx.ctx)

    assert %KitchenRun{status: :applied, artifacts: [%PlanDiff{} = diff]} = run(bubble)
    assert [%{change: :eating_out}] = PlanDiff.summarise(diff)
    assert State.eating_out?(plan(ctx.plan).slots["mon_dinner"])

    assert %{description: "Sushi", total_amount: amount} =
             Costs.get_dining_out(home_scope(), ctx.plan, "mon_dinner")

    assert Decimal.equal?(amount, 450)

    undo(bubble)
    assert plan(ctx.plan).slots["mon_dinner"].recipe_id == ctx.stew.id
    refute Costs.get_dining_out(home_scope(), ctx.plan, "mon_dinner")
  end

  test "an amount said later undoes back to the first one, still eating out", ctx do
    Dispatch.mark_eating_out(@monday, %{description: "Sushi", total_amount: nil}, ctx.ctx)
    later = Dispatch.mark_eating_out(@monday, %{total_amount: 600}, ctx.ctx)

    assert %KitchenRun{artifacts: [diff]} = run(later)
    assert [%{change: :eating_out}] = PlanDiff.summarise(diff)

    assert Decimal.equal?(
             Costs.get_dining_out(home_scope(), ctx.plan, "mon_dinner").total_amount,
             600
           )

    undo(later)

    assert %{description: "Sushi", total_amount: nil} =
             Costs.get_dining_out(home_scope(), ctx.plan, "mon_dinner")

    assert State.eating_out?(plan(ctx.plan).slots["mon_dinner"])
  end

  test "undoing a clear of an eating-out day brings its cost back too", ctx do
    Dispatch.mark_eating_out(@monday, %{description: "Sushi", total_amount: 300}, ctx.ctx)
    cleared = Dispatch.clear_plan_slot(@monday, ctx.ctx)
    refute Costs.get_dining_out(home_scope(), ctx.plan, "mon_dinner")

    undo(cleared)

    assert State.eating_out?(plan(ctx.plan).slots["mon_dinner"])

    assert %{description: "Sushi", total_amount: amount} =
             Costs.get_dining_out(home_scope(), ctx.plan, "mon_dinner")

    assert Decimal.equal?(amount, 300)
  end

  test "eating out works on an empty day, and undo empties it again", ctx do
    tuesday = Date.add(@monday, 1)
    bubble = Dispatch.mark_eating_out(tuesday, %{}, ctx.ctx)
    assert State.eating_out?(plan(ctx.plan).slots["tue_dinner"])

    undo(bubble)
    refute Map.has_key?(plan(ctx.plan).slots, "tue_dinner")
    refute Costs.get_dining_out(home_scope(), ctx.plan, "tue_dinner")
  end
end
