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

  describe "the same photo twice" do
    test "says it was already uploaded, without a link to nowhere" do
      household_id = home_scope().household_id
      image = <<255, 216, 255, 1, 2, 3>>

      {:ok, _} =
        Tore.Capture.Uploads.record(
          Tore.Scope.for_household(household_id),
          Tore.Capture.Uploads.content_hash(image),
          "kr_seen",
          "receipt"
        )

      bubble = Dispatch.ingest_receipt(image, capture_ctx(household_id))

      assert bubble.text =~ "already uploaded"
    end

    test "is read again when the first try failed" do
      test_pid = self()

      Mox.expect(Tore.MockLLM, :vision, 2, fn _images, _system, _user, _opts ->
        send(test_pid, :read)
        {:error, :timeout}
      end)

      image = <<255, 216, 255, 9, 9, 9>>
      ctx = capture_ctx(home_scope().household_id)

      Dispatch.ingest_receipt(image, ctx)
      bubble = Dispatch.ingest_receipt(image, ctx)

      assert_received :read
      assert_received :read
      refute bubble.text =~ "already uploaded"
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
      assert %{text: "Veckobudgeten är nu 2 000 kr."} =
               Dispatch.set_budget(Decimal.new(2000), nil, ctx)

      assert %{text: "Budgeten för vecka 47 är nu 1 500 kr."} =
               Dispatch.set_budget(Decimal.new(1500), ~D[2026-11-19], ctx)

      assert Tore.Budget.amount(home_scope(), ~D[2026-11-16]) == Decimal.new(1500)

      assert %{text: "Vecka 47 har den vanliga budgeten igen."} =
               Dispatch.set_budget(nil, ~D[2026-11-16], ctx)

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

    test "a typed total is a receipt with no lines in the week named, with undo", %{ctx: ctx} do
      last_week = Date.add(Tore.Streams.monday(Tore.Clock.today()), -7)
      week = Tore.Streams.week_number(last_week)

      assert %{text: text, run_stream_id: id} =
               Dispatch.log_total(Decimal.new(1900), Date.add(last_week, 2), ctx)

      assert text == "Lade in 1 900 kr för vecka #{week}."
      assert Decimal.eq?(Tore.Costs.spent_in_week(home_scope(), last_week), 1900)

      {:ok, _} = Runs.revert(home_scope(), id)
      assert Tore.Costs.spent_in_week(home_scope(), last_week) == nil

      next_week = Date.add(Tore.Clock.today(), 7)

      assert %{error: true, text: "Den veckan har inte börjat än."} =
               Dispatch.log_total(Decimal.new(100), next_week, ctx)
    end

    test "planning the week answers with its estimate against the budget", %{ctx: ctx} do
      import Mox

      {:ok, recipe} =
        Tore.Recipes.create(
          home_scope(),
          %{
            title: "Gryta",
            base_servings: 4,
            ingredients: [%{name: "bönor", quantity: 2, unit: "st"}]
          },
          image: false
        )

      Repo.update_all(
        Ecto.Query.from(i in Tore.Recipes.Ingredient, where: i.name == "bönor"),
        [set: [estimated_price: Decimal.new(15), estimated_unit: "st"]],
        Tore.Scope.repo_opts(home_scope())
      )

      Dispatch.set_budget(Decimal.new(500), ~D[2026-11-16], ctx)
      plan = Tore.Streams.plan(home_scope(), ~D[2026-11-16])
      {:ok, _} = Tore.Planning.assign_recipe(home_scope(), plan, "mon_dinner", recipe.id, 4)

      expect(Tore.MockLLM, :chat_with_tools, fn _, _, _, _ -> {:ok, {:message, "Klart."}, %{}} end)

      # Monday's stew, 30 kr, and six open days at a typical dinner, the same.
      assert %{
               text: "Planerade vecka 47: runt 210 av 500 kr, 0 av 1 ingredienser har pris.",
               run_stream_id: id
             } =
               Dispatch.plan_week(~D[2026-11-18], "planera veckan", ctx)

      assert %KitchenRun{kind: "planner_command_run"} = Runs.get(home_scope(), id)
    end
  end

  describe "can_i_make/4" do
    test "checks a recipe in the library by its own ingredients" do
      {:ok, buns} =
        Tore.Recipes.create(
          home_scope(),
          %{
            title: "Kanelbullar",
            recipe_type: :baking,
            ingredients: [%{name: "vetemjöl"}, %{name: "kanel"}, %{name: "smör"}]
          },
          image: false
        )

      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "vetemjöl"})
      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "smör"})

      bubble = Dispatch.can_i_make("kanelbullar", nil, ["ignored"], %{scope: home_scope()})

      assert %{recipe_id: id, baking: true, have: ["vetemjöl", "smör"], missing: ["kanel"]} =
               bubble.can_make

      assert id == buns.id
    end

    test "a dish not in the library is checked by the ingredients given for it" do
      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "ägg"})

      bubble =
        Dispatch.can_i_make("Pannkakor", nil, ["ägg", "mjölk", "vetemjöl"], %{scope: home_scope()})

      assert %{recipe_id: nil, title: "Pannkakor", have: ["ägg"], missing: ["mjölk", "vetemjöl"]} =
               bubble.can_make
    end

    test "a plain question makes no model call; saying what's lacking asks for swaps once" do
      {:ok, stew} =
        Tore.Recipes.create(
          home_scope(),
          %{
            title: "Kycklinggryta",
            recipe_type: :meal,
            ingredients: [%{name: "kyckling"}, %{name: "crème fraîche"}]
          },
          image: false
        )

      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "kyckling"})
      {:ok, _} = Tore.Pantry.add_item(home_scope(), %{name: "crème fraîche"})

      assert %{missing: [], swaps: nil} =
               Dispatch.can_i_make("kycklinggryta", stew.id, [], %{scope: home_scope()}).can_make

      Mox.expect(Tore.MockLLM, :text, fn _system, user, _opts ->
        assert %{"missing" => ["crème fraîche"], "they_have" => "gräddfil"} = Jason.decode!(user)

        {:ok, %{"swaps" => [%{"for" => "crème fraîche", "use" => "gräddfil", "note" => nil}]},
         %{}}
      end)

      bubble =
        Dispatch.can_i_make("kycklinggryta", stew.id, [], %{scope: home_scope()},
          lacking: ["Crème fraîche"],
          instead: "gräddfil"
        )

      assert %{have: ["kyckling"], missing: ["crème fraîche"], swaps: [%{use: "gräddfil"}]} =
               bubble.can_make
    end
  end
end
