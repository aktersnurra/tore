defmodule Tore.Harness.Kinds.ShopEditTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Pantry, Planning, Recipes, Shop, Streams}
  alias Tore.Capture.Dispatch
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.ShopChange

  setup :verify_on_exit!

  setup do
    stub(Tore.MockHTTP, :fetch, fn _url -> {:error, :not_found} end)
    # One answer serves both the section classifier and the pantry canonicaliser.
    stub(Tore.MockLLM, :text, fn _, _, _ ->
      {:ok, %{"section" => "dairy", "items" => []}, %{}}
    end)

    user = user_fixture()
    %{ctx: %{household_id: home_scope().household_id, user_id: user.id}}
  end

  defp list(date \\ Date.utc_today()) do
    {:ok, state} = Shop.load_list(home_scope(), Streams.shop_list(home_scope(), date))
    state.items |> Map.values() |> Enum.map(&Map.take(&1, [:name, :checked, :section]))
  end

  defp undo(%{run_stream_id: id}), do: Runs.revert(home_scope(), id)

  test "an added item can be undone", %{ctx: ctx} do
    bubble = Dispatch.add_to_shopping_list("mjölk", 2, "l", ctx)

    assert %KitchenRun{
             status: :applied,
             kind: "shop_edit_run",
             surface: :shop,
             artifacts: [%ShopChange{change: :add}]
           } = Runs.get(home_scope(), bubble.run_stream_id)

    assert list() == [%{name: "mjölk", checked: false, section: :dairy}]

    {:ok, _} = undo(bubble)
    assert list() == []
  end

  test "undoing a check-off unchecks it and takes it back out of the pantry", %{ctx: ctx} do
    Dispatch.add_to_shopping_list("smör", nil, nil, ctx)

    bubble = Dispatch.check_off_shopping_item("smör", ctx)
    assert [%{checked: true}] = list()
    assert Enum.map(Pantry.list_inventory(home_scope()), & &1.name) == ["smör"]

    {:ok, _} = undo(bubble)
    assert [%{checked: false}] = list()
    assert Pantry.list_inventory(home_scope()) == []
  end

  test "undoing an add after the item was removed counts as done", %{ctx: ctx} do
    bubble = Dispatch.add_to_shopping_list("ost", nil, nil, ctx)
    list_id = Streams.shop_list(home_scope(), Date.utc_today())
    {:ok, %{items: items}} = Shop.load_list(home_scope(), list_id)
    [id] = Map.keys(items)
    {:ok, _} = Shop.remove_item(home_scope(), list_id, id, nil)

    assert {:ok, %KitchenRun{status: :reverted}} = undo(bubble)
  end

  test "building the week's list replaces it and offers no undo", %{ctx: ctx} do
    monday = Streams.monday(Date.utc_today())
    plan = Streams.plan(home_scope(), monday)

    {:ok, soup} =
      Recipes.create(home_scope(), %{
        title: "Soup",
        base_servings: 4,
        image_url: "https://x/y.jpg",
        ingredients: [%{name: "morot", quantity: Decimal.new("3"), unit: "st"}]
      })

    {:ok, _} = Planning.assign_recipe(home_scope(), plan, "mon_dinner", soup.id, 4)
    Dispatch.add_to_shopping_list("gammalt", nil, nil, ctx)

    bubble = Dispatch.generate_shopping_list_from_plan(monday, ctx)

    refute Map.has_key?(bubble, :run_stream_id)
    assert [%{name: "morot", checked: false}] = list(monday)

    [run] =
      Repo.all(
        from(r in KitchenRun, where: r.kind == "shop_edit_run" and r.status == :applied),
        Tore.Scope.repo_opts(home_scope())
      )
      |> Enum.filter(&match?([%ShopChange{change: :build}], &1.artifacts))

    assert {:irreversible, _} = run.undo
    assert {:error, :irreversible} = Runs.revert(home_scope(), run.id)
  end
end
