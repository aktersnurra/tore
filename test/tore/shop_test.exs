defmodule Tore.ShopTest do
  use ExUnit.Case, async: false

  import Tore.AccountsFixtures, only: [home_scope: 0]

  alias Tore.Shop

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Tore.Repo)
    Phoenix.PubSub.subscribe(Tore.PubSub, Shop.topic(home_scope()))

    :ok
  end

  defp list_id, do: Tore.Streams.shop_list(home_scope(), ~D[2026-04-27])

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

  test "add_item leaves a name already on the list alone, until it's ticked off" do
    Shop.add_item(home_scope(), list_id(), "Gul lök", Decimal.new("3"), "st", 1)
    assert {:ok, []} = Shop.add_item(home_scope(), list_id(), "gul lök ", nil, nil, 1)

    {:ok, state} = Shop.load_list(home_scope(), list_id())
    assert [%{name: "Gul lök", id: id}] = Map.values(state.items)

    Shop.check_item(home_scope(), list_id(), id, 1)
    Shop.add_item(home_scope(), list_id(), "Gul lök", nil, nil, 1)
    {:ok, state} = Shop.load_list(home_scope(), list_id())
    assert state.items |> Map.values() |> Enum.count(&(&1.name == "Gul lök")) == 2
  end

  test "add_item broadcasts to shop_list topic" do
    Shop.add_item(home_scope(), list_id(), "Eggs", nil, nil, 1)
    assert_receive {:events, [%Tore.Shop.Events.ItemAdded{}]}
  end

  test "a list change is broadcast only to its own household" do
    other = Tore.AccountsFixtures.scope_fixture(Tore.AccountsFixtures.household_fixture())
    Phoenix.PubSub.subscribe(Tore.PubSub, Shop.topic(other))

    Shop.add_item(home_scope(), list_id(), "Eggs", nil, nil, 1)

    assert_receive {:events, [%Tore.Shop.Events.ItemAdded{}]}
    refute_received {:events, _}
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

  describe "parse_line/1" do
    test "reads an amount, a unit and the name, as people type them" do
      assert Shop.parse_line("2 l mjölk") == {"mjölk", Decimal.new("2"), "l"}
      assert Shop.parse_line("1,5 kg potatis") == {"potatis", Decimal.new("1.5"), "kg"}
      assert Shop.parse_line("500g köttfärs") == {"köttfärs", Decimal.new("500"), "g"}
      assert Shop.parse_line("3 Paket smör") == {"smör", Decimal.new("3"), "paket"}
    end

    test "a number with no unit counts things; no number is just a name" do
      assert Shop.parse_line("6 ägg") == {"ägg", Decimal.new("6"), nil}
      assert Shop.parse_line("  bananer ") == {"bananer", nil, nil}
    end

    test "a word that starts like a unit is the name" do
      assert Shop.parse_line("2 lime") == {"lime", Decimal.new("2"), nil}
      assert Shop.parse_line("gurka") == {"gurka", nil, nil}
    end

    test "a number alone is kept as the name rather than lost" do
      assert Shop.parse_line("7up") == {"7up", nil, nil}
      assert Shop.parse_line("2 l") == {"2 l", nil, nil}
    end
  end

  describe "dinners_for/3" do
    defp dinner(title, names) do
      {:ok, r} =
        Tore.Recipes.create(
          home_scope(),
          %{title: title, ingredients: Enum.map(names, &%{name: &1})},
          image: false
        )

      r
    end

    test "names the first dinner from today on that needs each ingredient" do
      monday = ~D[2026-11-16]
      plan = Tore.Streams.plan(home_scope(), monday)
      tacos = dinner("Tacos", ["tortilla", "köttfärs"])
      lasagne = dinner("Lasagne", ["köttfärs", "pasta"])
      soup = dinner("Soppa", ["purjolök"])
      {:ok, _} = Tore.Planning.assign_recipe(home_scope(), plan, "mon_dinner", soup.id, 4)
      {:ok, _} = Tore.Planning.assign_recipe(home_scope(), plan, "tue_dinner", tacos.id, 4)
      {:ok, _} = Tore.Planning.assign_recipe(home_scope(), plan, "thu_dinner", lasagne.id, 4)

      for_item = Shop.dinners_for(home_scope(), monday, ~D[2026-11-17])

      key = &Tore.Recipes.Ingredient.to_key/1
      assert for_item[key.("köttfärs")] == %{date: ~D[2026-11-17], title: "Tacos"}
      assert for_item[key.("pasta")] == %{date: ~D[2026-11-19], title: "Lasagne"}
      refute Map.has_key?(for_item, key.("purjolök"))
    end
  end
end
