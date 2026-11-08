defmodule Tore.ShopTest do
  use ExUnit.Case, async: false

  import Tore.AccountsFixtures, only: [home_scope: 0]

  import Mox

  alias Tore.{Shop, Recipes}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
    Phoenix.PubSub.subscribe(Tore.PubSub, Shop.topic(home_scope()))

    # Shop.add_item/build_list/check_item call Tore.LLM.text/3 to classify
    # items, filter the pantry, and canonicalise pantry beliefs. Stub a
    # response shape that satisfies all three: section for classify,
    # items: [] for filter, and an empty items list for the canonicaliser
    # (its caller falls back to raw names when nothing matches).
    stub(Tore.MockLLM, :text, fn _system, _user, _opts ->
      {:ok, %{"section" => "other", "items" => []}, %{}}
    end)

    :ok
  end

  defp list_id, do: Tore.Streams.shop_list(home_scope(), ~D[2026-04-27])
  defp week_start, do: ~D[2026-04-27]

  test "load_list returns initial state for new list" do
    assert {:ok, state} = Shop.load_list(home_scope(), list_id())
    assert state.items == %{}
  end

  test "add_item persists ItemAdded with generated item_id" do
    assert {:ok, _events} =
             Shop.add_item(home_scope(), list_id(), "Milk", Decimal.new("1"), "l", 1)

    assert {:ok, state} = Shop.load_list(home_scope(), list_id())
    item = state.items |> Map.values() |> List.first()
    assert item.name == "Milk"
    assert item.unit == "l"
    assert item.checked == false
  end

  test "add_item broadcasts to shop_list topic" do
    Shop.add_item(home_scope(), list_id(), "Eggs", nil, nil, 1)
    assert_receive {:events, [%Tore.Shop.Events.ItemAdded{}]}
  end

  test "check_item persists ItemChecked and broadcasts" do
    Shop.add_item(home_scope(), list_id(), "Butter", nil, nil, 1)
    {:ok, state} = Shop.load_list(home_scope(), list_id())
    item_id = state.items |> Map.keys() |> List.first()

    assert {:ok, _} = Shop.check_item(home_scope(), list_id(), item_id, 1)
    {:ok, updated} = Shop.load_list(home_scope(), list_id())
    assert updated.items[item_id].checked == true

    assert_receive {:events, [%Tore.Shop.Events.ItemChecked{}]}
  end

  test "check_item returns error for unknown item_id" do
    assert {:error, :item_not_found} = Shop.check_item(home_scope(), list_id(), "no-such-id", 1)
  end

  test "check_item adds item to pantry" do
    Shop.add_item(home_scope(), list_id(), "Pasta", Decimal.new("500"), "g", 1)
    {:ok, state} = Shop.load_list(home_scope(), list_id())
    item_id = state.items |> Map.keys() |> List.first()

    Shop.check_item(home_scope(), list_id(), item_id, 1)
    pantry = Tore.Pantry.list_inventory(home_scope())
    assert Enum.any?(pantry, &(&1.name == "pasta"))
  end

  test "build_list aggregates recipe ingredients and broadcasts" do
    {:ok, recipe} =
      Recipes.create(home_scope(), %{
        title: "Test Recipe",
        ingredients: [%{name: "onion", quantity: Decimal.new("2"), unit: "pcs"}]
      })

    assert {:ok, _} = Shop.build_list(home_scope(), list_id(), week_start(), [recipe.id])
    {:ok, state} = Shop.load_list(home_scope(), list_id())
    item = state.items |> Map.values() |> Enum.find(&(&1.name == "onion"))
    assert item
    assert_receive {:events, [%Tore.Shop.Events.ListBuilt{}]}
  end

  test "annotate_with_pantry_belief/1 tags items whose name matches a non-missing pantry row" do
    {:ok, _, _, _} =
      Tore.Pantry.upsert_belief(home_scope(), %{catalogue_name: "Milk", provenance: "receipt"})

    items = [
      %{id: "a", name: "milk", quantity: nil, unit: nil, checked: false},
      %{id: "b", name: "saffron", quantity: nil, unit: nil, checked: false}
    ]

    [milk, saffron] = Shop.annotate_with_pantry_belief(home_scope(), items)

    assert milk.pantry_belief == :probable
    assert %DateTime{} = milk.pantry_last_seen_at
    assert saffron.pantry_belief == nil
    assert saffron.pantry_last_seen_at == nil
  end

  test "annotate_with_pantry_belief/1 does not match on partial-word overlaps" do
    {:ok, _, _, _} =
      Tore.Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Graham flour",
        provenance: "manual"
      })

    {:ok, _, _, _} =
      Tore.Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Buttermilk",
        provenance: "manual"
      })

    {:ok, _, _, _} =
      Tore.Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Salted butter",
        provenance: "manual"
      })

    items = [
      %{id: "a", name: "ham", quantity: nil, unit: nil, checked: false},
      %{id: "b", name: "milk", quantity: nil, unit: nil, checked: false},
      %{id: "c", name: "salt", quantity: nil, unit: nil, checked: false}
    ]

    [ham, milk, salt] = Shop.annotate_with_pantry_belief(home_scope(), items)

    assert ham.pantry_belief == nil
    assert milk.pantry_belief == nil
    assert salt.pantry_belief == nil
  end

  test "annotate_with_pantry_belief/1 matches when one full token is shared" do
    {:ok, _, _, _} =
      Tore.Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Whole milk",
        provenance: "manual"
      })

    [annotated] =
      Shop.annotate_with_pantry_belief(home_scope(), [
        %{id: "x", name: "Milk, 1L", quantity: nil, unit: nil, checked: false}
      ])

    assert annotated.pantry_belief == :confirmed
  end

  test "annotate_with_pantry_belief/1 surfaces decayed belief, not stored belief" do
    {:ok, item, _, _} =
      Tore.Pantry.upsert_belief(home_scope(), %{catalogue_name: "Old milk", provenance: "vision"})

    backdated = DateTime.utc_now() |> DateTime.add(-20, :day) |> DateTime.truncate(:second)

    item
    |> Ecto.Changeset.change(last_seen_at: backdated)
    |> Tore.Repo.update!()

    [annotated] =
      Tore.Shop.annotate_with_pantry_belief(home_scope(), [
        %{id: "x", name: "old milk", quantity: nil, unit: nil, checked: false}
      ])

    assert annotated.pantry_belief == :probable
  end

  test "annotate_with_pantry_belief/1 ignores pantry rows that are missing" do
    {:ok, item, _, _} =
      Tore.Pantry.upsert_belief(home_scope(), %{catalogue_name: "Yeast", provenance: "manual"})

    item
    |> Ecto.Changeset.change(belief: "missing")
    |> Tore.Repo.update!()

    [annotated] =
      Shop.annotate_with_pantry_belief(home_scope(), [
        %{id: "x", name: "yeast", quantity: nil, unit: nil, checked: false}
      ])

    assert annotated.pantry_belief == nil
  end

  test "build_list filters only against pantry items still within their date" do
    {:ok, _} =
      Tore.Pantry.add_item(home_scope(), %{name: "färsk ost", expires_at: Date.utc_today()})

    {:ok, _} =
      Tore.Pantry.add_item(home_scope(), %{
        name: "gammal ost",
        expires_at: Date.add(Date.utc_today(), -1)
      })

    test_pid = self()

    stub(Tore.MockLLM, :text, fn _system, user, _opts ->
      send(test_pid, {:filter_prompt, user})
      {:ok, %{"items" => []}, %{}}
    end)

    Shop.build_list(
      home_scope(),
      Tore.Streams.shop_list(home_scope(), ~D[2026-11-02]),
      ~D[2026-11-02],
      []
    )

    assert_received {:filter_prompt, prompt}
    assert prompt =~ "färsk ost"
    refute prompt =~ "gammal ost"
  end
end
