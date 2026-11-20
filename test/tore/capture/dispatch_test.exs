defmodule Tore.Capture.DispatchTest do
  use Tore.DataCase, async: false

  alias Tore.Capture.Dispatch
  alias Tore.Harness.{KitchenRun, Runs}

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

      ctx = capture_ctx(1, user_fixture().id)

      assert %{text: "La till Carbonara på måndag 2026-11-02."} =
               Dispatch.set_plan_slot(~D[2026-11-02], recipe.id, 4, ctx)

      assert %{text: "Hoppade över måndag 2026-11-02."} =
               Dispatch.skip_plan_meal(~D[2026-11-02], capture_ctx(home_scope().household_id))
    end
  end

  describe "a lunch and days off" do
    test "a lunch sits beside the dinner, and days off are said back" do
      Gettext.put_locale(ToreWeb.Gettext, "sv")

      {:ok, recipe} =
        %Tore.Recipes.Recipe{
          household_id: home_scope().household_id,
          title: "Ärtsoppa",
          recipe_type: :meal
        }
        |> Tore.Repo.insert()

      ctx = capture_ctx(1, user_fixture().id)

      assert %{text: "La till Ärtsoppa på lördagslunch 2026-11-07."} =
               Dispatch.set_plan_slot(~D[2026-11-07], recipe.id, nil, ctx, :lunch)

      plan = Tore.Streams.plan(home_scope(), ~D[2026-11-07])
      {:ok, state} = Tore.Planning.load_plan(home_scope(), plan)
      assert Map.keys(state.slots) == ["sat_lunch"]

      assert %{text: "Lediga dagar: 2026-11-05, 2026-11-06."} =
               Dispatch.set_days_off([~D[2026-11-06], ~D[2026-11-05]], true, ctx)

      {:ok, state} = Tore.Planning.load_plan(home_scope(), plan)
      assert MapSet.equal?(state.days_off, MapSet.new([~D[2026-11-05], ~D[2026-11-06]]))
    end
  end

  describe "set_plan_slot/2" do
    test "applies through a run whose Undo the bubble carries" do
      {:ok, recipe} =
        %Tore.Recipes.Recipe{
          household_id: home_scope().household_id,
          title: "Carbonara",
          recipe_type: :meal
        }
        |> Tore.Repo.insert()

      ctx = capture_ctx(1, user_fixture().id)
      bubble = Dispatch.set_plan_slot(~D[2026-06-23], recipe.id, 4, ctx)

      assert bubble.role == :assistant
      assert bubble.text =~ "Carbonara"

      assert %KitchenRun{status: :applied, kind: "set_plan_slot_run"} =
               Runs.get(home_scope(), bubble.run_stream_id)
    end

    test "says so, and leaves the day, when the day is pinned" do
      Gettext.put_locale(ToreWeb.Gettext, "sv")

      {:ok, recipe} =
        %Tore.Recipes.Recipe{
          household_id: home_scope().household_id,
          title: "Carbonara",
          recipe_type: :meal
        }
        |> Tore.Repo.insert()

      plan = Tore.Streams.plan(home_scope(), ~D[2026-06-23])
      {:ok, _} = Tore.Planning.pin_slot(home_scope(), plan, "tue_dinner", true)

      bubble =
        Dispatch.set_plan_slot(~D[2026-06-23], recipe.id, 4, capture_ctx(1, user_fixture().id))

      assert bubble.text =~ "tisdag"
      refute Map.has_key?(bubble, :run_stream_id)
      {:ok, state} = Tore.Planning.load_plan(home_scope(), plan)
      refute Map.has_key?(state.slots, "tue_dinner")
    end

    test "replies with an error when the recipe does not exist" do
      bubble =
        Dispatch.set_plan_slot(~D[2026-06-23], 999_999, 4, capture_ctx(1, user_fixture().id))

      assert bubble.role == :assistant
      refute Map.has_key?(bubble, :run_stream_id)
    end
  end

  describe "mark_eating_out/3" do
    setup do
      user = user_fixture(name: "Tester")
      %{ctx: capture_ctx(1, user.id)}
    end

    test "marks the day, and a later call adds the amount", %{ctx: ctx} do
      date = ~D[2026-11-13]

      assert %{text: text} =
               Dispatch.mark_eating_out(date, %{place: "Sushi"}, ctx)

      assert text =~ "2026-11-13"

      Dispatch.mark_eating_out(date, %{amount: 450}, ctx)

      {:ok, state} =
        Tore.Planning.load_plan(home_scope(), Tore.Streams.plan(home_scope(), ~D[2026-11-09]))

      assert %{place: "Sushi", amount: "450"} = state.slots["fri_dinner"]
    end
  end

  describe "budget" do
    setup do
      Gettext.put_locale(ToreWeb.Gettext, "sv")
      %{ctx: capture_ctx(home_scope().household_id, user_fixture().id)}
    end

    test "the usual budget, a week's own, and back", %{ctx: ctx} do
      assert %{text: "Veckobudgeten är 2 000 kr från vecka 47."} =
               Dispatch.set_budget(Decimal.new(2000), {:from, ~D[2026-11-18]}, ctx)

      assert %{text: "Budgeten för vecka 47 är nu 1 500 kr."} =
               Dispatch.set_budget(Decimal.new(1500), {:week, ~D[2026-11-19]}, ctx)

      assert Tore.Budget.amount(home_scope(), ~D[2026-11-16]) == Decimal.new(1500)

      assert %{text: "Vecka 47 har den vanliga budgeten igen."} =
               Dispatch.set_budget(nil, {:week, ~D[2026-11-16]}, ctx)

      assert Tore.Budget.amount(home_scope(), ~D[2026-11-16]) == Decimal.new(2000)
    end

    test "basics the person names go on every week's list, and stop when asked", %{ctx: ctx} do
      items = [
        %{name: "Havregryn", quantity: nil, unit: nil},
        %{name: "Mjölk", quantity: Decimal.new(3), unit: "l"}
      ]

      assert %{text: "Havregryn, Mjölk hamnar på listan varje vecka."} =
               Dispatch.set_basics(items, false, ctx)

      assert ["Havregryn", "Mjölk"] = Enum.map(Tore.Basics.list(home_scope()), & &1.name)

      assert %{text: "havregryn läggs inte till på listan längre."} =
               Dispatch.set_basics([%{name: "havregryn", quantity: nil, unit: nil}], true, ctx)

      assert ["Mjölk"] = Enum.map(Tore.Basics.list(home_scope()), & &1.name)
    end
  end
end
