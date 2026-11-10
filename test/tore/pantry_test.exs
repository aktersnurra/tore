defmodule Tore.PantryTest do
  use Tore.DataCase, async: false

  alias Tore.Pantry

  test "add_item/1 inserts and returns pantry item" do
    assert {:ok, item} =
             Pantry.add_item(home_scope(), %{name: "Mjölk", quantity: Decimal.new(2), unit: "L"})

    assert item.name == "mjölk"
    assert item.added_at == Date.utc_today()
  end

  test "add_item/1 defaults added_at to today when omitted" do
    assert {:ok, item} = Pantry.add_item(home_scope(), %{name: "Smör"})
    assert item.added_at == Date.utc_today()
  end

  test "add_item/1 returns error on missing name" do
    assert {:error, changeset} = Pantry.add_item(home_scope(), %{quantity: Decimal.new(1)})
    assert changeset.errors[:name]
  end

  test "remove_item/1 deletes existing item and returns :ok" do
    {:ok, item} = Pantry.add_item(home_scope(), %{name: "Ägg"})
    assert :ok = Pantry.remove_item(home_scope(), item.id)
    assert Pantry.list_inventory(home_scope()) == []
  end

  test "remove_item/1 returns error for unknown id" do
    assert {:error, :not_found} = Pantry.remove_item(home_scope(), 999_999)
  end

  test "list_inventory/0 returns all items ordered by name" do
    Pantry.add_item(home_scope(), %{name: "Ost"})
    Pantry.add_item(home_scope(), %{name: "Bröd"})
    names = Pantry.list_inventory(home_scope()) |> Enum.map(& &1.name)
    assert names == ["bröd", "ost"]
  end

  test "add_item/1 accepts valid category" do
    assert {:ok, item} = Pantry.add_item(home_scope(), %{name: "Mjölk", category: "dairy"})
    assert item.category == "dairy"
  end

  test "add_item/1 rejects invalid category" do
    assert {:error, changeset} =
             Pantry.add_item(home_scope(), %{name: "Mjölk", category: "invalid"})

    assert changeset.errors[:category]
  end

  test "PantryItem.categories/0 returns ordered list of atoms" do
    cats = Tore.Pantry.PantryItem.categories()
    assert is_list(cats)
    assert Enum.all?(cats, &is_atom/1)
    assert :dairy in cats
    assert :meat in cats
    assert :other in cats
  end

  test "PantryItem.beliefs/0 returns the four belief values as strings" do
    assert Tore.Pantry.PantryItem.beliefs() == ~w[confirmed probable uncertain missing]
  end

  test "add_item/1 defaults belief to confirmed for manual provenance" do
    {:ok, item} = Pantry.add_item(home_scope(), %{name: "Salt"})
    assert item.provenance == "manual"
    assert item.belief == "confirmed"
  end

  test "add_item/1 accepts an explicit belief value" do
    {:ok, item} = Pantry.add_item(home_scope(), %{name: "Mjöl", belief: "probable"})
    assert item.belief == "probable"
  end

  test "add_item/1 rejects an invalid belief value" do
    assert {:error, changeset} = Pantry.add_item(home_scope(), %{name: "Sirap", belief: "maybe"})
    assert changeset.errors[:belief]
  end

  test "PantryItem.derive_belief/1 maps provenance to default belief" do
    assert Tore.Pantry.PantryItem.derive_belief("manual") == "confirmed"
    assert Tore.Pantry.PantryItem.derive_belief("vision") == "confirmed"
    assert Tore.Pantry.PantryItem.derive_belief("receipt") == "probable"
    assert Tore.Pantry.PantryItem.derive_belief("grocery_checkoff") == "probable"
    assert Tore.Pantry.PantryItem.derive_belief("belief") == "uncertain"
  end

  test "upsert_belief/1 bump refreshes belief from incoming provenance" do
    {:ok, _item, :added, nil} =
      Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Mjölk",
        quantity: Decimal.new(1),
        unit: "L",
        provenance: "belief"
      })

    {:ok, bumped, :bumped, _before} =
      Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Mjölk",
        quantity: Decimal.new(1),
        unit: "L",
        provenance: "receipt"
      })

    assert bumped.belief == "probable"
  end

  test "upsert_belief/1 bump sums quantities when units match" do
    {:ok, _, _, _} =
      Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Milk",
        quantity: Decimal.new(1),
        unit: "L",
        provenance: "manual"
      })

    {:ok, bumped, :bumped, _} =
      Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Milk",
        quantity: Decimal.new(2),
        unit: "L",
        provenance: "receipt"
      })

    assert Decimal.equal?(bumped.quantity, Decimal.new(3))
    assert bumped.unit == "L"
  end

  test "upsert_belief/1 bump does NOT sum quantities when units conflict" do
    {:ok, existing, _, _} =
      Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Milk",
        quantity: Decimal.new(1),
        unit: "L",
        provenance: "manual"
      })

    {:ok, bumped, :bumped, _} =
      Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Milk",
        quantity: Decimal.new(500),
        unit: "ml",
        provenance: "receipt"
      })

    # Existing quantity wins; the signal (we saw it again) still
    # refreshes last_seen_at / provenance / belief.
    assert Decimal.equal?(bumped.quantity, existing.quantity)
    assert bumped.unit == "L"
    assert bumped.provenance == "receipt"
    assert DateTime.compare(bumped.last_seen_at, existing.last_seen_at) in [:gt, :eq]
  end

  test "upsert_belief/1 bump treats nil incoming unit as compatible" do
    {:ok, _, _, _} =
      Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Eggs",
        quantity: Decimal.new(6),
        unit: "pcs",
        provenance: "manual"
      })

    {:ok, bumped, :bumped, _} =
      Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Eggs",
        quantity: Decimal.new(6),
        provenance: "grocery_checkoff"
      })

    assert Decimal.equal?(bumped.quantity, Decimal.new(12))
    assert bumped.unit == "pcs"
  end

  test "upsert_belief/1 bump never weakens a confirmed belief" do
    {:ok, _item, :added, nil} =
      Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Smör",
        quantity: Decimal.new(1),
        unit: "kg",
        provenance: "vision"
      })

    {:ok, bumped, :bumped, _before} =
      Pantry.upsert_belief(home_scope(), %{
        catalogue_name: "Smör",
        quantity: Decimal.new(1),
        unit: "kg",
        provenance: "belief"
      })

    assert bumped.belief == "confirmed"
  end

  test "PantryItem.effective_belief/2 decays confirmed → probable after 14 days" do
    now = ~U[2026-06-29 12:00:00Z]
    fresh = %Tore.Pantry.PantryItem{belief: "confirmed", last_seen_at: ~U[2026-06-20 12:00:00Z]}
    stale = %Tore.Pantry.PantryItem{belief: "confirmed", last_seen_at: ~U[2026-06-10 12:00:00Z]}

    assert Tore.Pantry.PantryItem.effective_belief(fresh, now) == :confirmed
    assert Tore.Pantry.PantryItem.effective_belief(stale, now) == :probable
  end

  test "PantryItem.effective_belief/2 decays probable → uncertain after 30 days" do
    now = ~U[2026-06-29 12:00:00Z]
    fresh = %Tore.Pantry.PantryItem{belief: "probable", last_seen_at: ~U[2026-06-10 12:00:00Z]}
    stale = %Tore.Pantry.PantryItem{belief: "probable", last_seen_at: ~U[2026-05-01 12:00:00Z]}

    assert Tore.Pantry.PantryItem.effective_belief(fresh, now) == :probable
    assert Tore.Pantry.PantryItem.effective_belief(stale, now) == :uncertain
  end

  test "PantryItem.effective_belief/2 leaves uncertain and missing untouched" do
    now = ~U[2026-06-29 12:00:00Z]
    ancient = ~U[2024-01-01 00:00:00Z]
    uncertain = %Tore.Pantry.PantryItem{belief: "uncertain", last_seen_at: ancient}
    missing = %Tore.Pantry.PantryItem{belief: "missing", last_seen_at: ancient}

    assert Tore.Pantry.PantryItem.effective_belief(uncertain, now) == :uncertain
    assert Tore.Pantry.PantryItem.effective_belief(missing, now) == :missing
  end

  test "PantryItem.effective_belief/2 with no last_seen_at returns stored belief" do
    item = %Tore.Pantry.PantryItem{belief: "confirmed", last_seen_at: nil}
    assert Tore.Pantry.PantryItem.effective_belief(item, ~U[2026-06-29 12:00:00Z]) == :confirmed
  end

  test "list_inventory_by_belief/0 groups by *effective* belief, not stored" do
    {:ok, item, _, _} =
      Pantry.upsert_belief(home_scope(), %{catalogue_name: "Old milk", provenance: "vision"})

    # Backdate last_seen_at into the probable window (>14 days, <30 days)
    # so the confirmed row should decay to probable at read time.
    backdated = DateTime.utc_now() |> DateTime.add(-20, :day) |> DateTime.truncate(:second)

    item
    |> Ecto.Changeset.change(last_seen_at: backdated)
    |> Tore.Repo.update!()

    groups = Pantry.list_inventory_by_belief(home_scope())
    assert {:probable, [decayed]} = Enum.find(groups, fn {b, _} -> b == :probable end)
    assert decayed.name == "old milk"
  end

  test "list_inventory_by_belief/0 groups items by belief in confidence order" do
    {:ok, _, _, _} =
      Pantry.upsert_belief(home_scope(), %{catalogue_name: "Mjölk", provenance: "receipt"})

    {:ok, _, _, _} =
      Pantry.upsert_belief(home_scope(), %{catalogue_name: "Salt", provenance: "manual"})

    {:ok, _, _, _} =
      Pantry.upsert_belief(home_scope(), %{catalogue_name: "Mjöl", provenance: "belief"})

    groups = Pantry.list_inventory_by_belief(home_scope())
    keys = Enum.map(groups, &elem(&1, 0))

    assert keys == [:confirmed, :probable, :uncertain]
  end

  describe "shelf life" do
    alias Tore.Pantry.PantryItem
    alias Tore.Recipes.Ingredient

    defp seen(belief, days_ago, expires_at) do
      now = ~U[2026-11-05 12:00:00Z]

      PantryItem.effective_belief(
        %PantryItem{
          belief: belief,
          last_seen_at: DateTime.add(now, -days_ago, :day),
          expires_at: expires_at
        },
        now
      )
    end

    test "with a date, an item is confirmed for up to 14 days, then probable until the date" do
      assert seen("confirmed", 3, ~D[2027-01-01]) == :confirmed
      assert seen("confirmed", 15, ~D[2027-01-01]) == :probable
      assert seen("confirmed", 200, ~D[2027-01-01]) == :probable
      assert seen("probable", 200, ~D[2027-01-01]) == :probable
    end

    test "past its date an item is uncertain, however recently it was seen" do
      assert seen("confirmed", 0, ~D[2026-11-05]) == :confirmed
      assert seen("confirmed", 0, ~D[2026-11-04]) == :uncertain
      assert seen("probable", 0, ~D[2026-11-04]) == :uncertain
    end

    test "a date doesn't bring back an item we believe is missing" do
      assert seen("missing", 0, ~D[2027-01-01]) == :missing
      assert seen("uncertain", 0, ~D[2027-01-01]) == :uncertain
    end

    test "with no date, the fixed decay still applies" do
      assert seen("confirmed", 15, nil) == :probable
      assert seen("confirmed", 31, nil) == :uncertain
    end

    test "buying an item stores the guess on the ingredient and dates the row" do
      {:ok, item, :added, _} =
        Pantry.upsert_belief(home_scope(), %{
          catalogue_name: "Mjölk",
          provenance: "grocery_checkoff",
          shelf_life_days: 7
        })

      assert Repo.get(Ingredient, item.ingredient_id, Tore.Scope.repo_opts(home_scope())).shelf_life_days ==
               7

      assert item.expires_at == Date.add(Date.utc_today(), 7)
      assert item.expires_source == "estimate"
    end

    test "a new guess doesn't overwrite the shelf life we have" do
      attrs = %{catalogue_name: "Mjölk", provenance: "grocery_checkoff"}

      {:ok, item, :added, _} =
        Pantry.upsert_belief(home_scope(), Map.put(attrs, :shelf_life_days, 7))

      {:ok, item, :bumped, _} =
        Pantry.upsert_belief(home_scope(), Map.put(attrs, :shelf_life_days, 30))

      assert Repo.get(Ingredient, item.ingredient_id, Tore.Scope.repo_opts(home_scope())).shelf_life_days ==
               7

      assert item.expires_at == Date.add(Date.utc_today(), 7)
    end

    test "a guess fills in an ingredient that has no shelf life, keeping its key" do
      {:ok, ingredient} =
        %Ingredient{household_id: home_scope().household_id}
        |> Ingredient.changeset(%{name: "Mjölk", key: "mellanmjolk"})
        |> Repo.insert()

      {:ok, _, :added, _} =
        Pantry.upsert_belief(home_scope(), %{
          catalogue_name: "Mjölk",
          matched_key: "mellanmjolk",
          provenance: "grocery_checkoff",
          shelf_life_days: 7
        })

      updated = Repo.get(Ingredient, ingredient.id, Tore.Scope.repo_opts(home_scope()))
      assert updated.shelf_life_days == 7
      assert updated.key == "mellanmjolk"
    end

    test "changing a date sticks through a photo and teaches the shelf life" do
      {:ok, item, :added, _} =
        Pantry.upsert_belief(home_scope(), %{
          catalogue_name: "Mjölk",
          provenance: "grocery_checkoff",
          shelf_life_days: 7
        })

      chosen = Date.add(Date.utc_today(), 12)
      assert {:ok, updated} = Pantry.set_expiry(home_scope(), item.id, chosen)
      assert updated.expires_at == chosen
      assert updated.expires_source == "manual"

      assert Repo.get(Ingredient, item.ingredient_id, Tore.Scope.repo_opts(home_scope())).shelf_life_days ==
               12

      {:ok, seen, :bumped, _} =
        Pantry.upsert_belief(home_scope(), %{
          catalogue_name: "Mjölk",
          provenance: "vision",
          expires_on: ~D[2030-01-01]
        })

      assert seen.expires_at == chosen

      {:ok, bought, :bumped, _} =
        Pantry.upsert_belief(home_scope(), %{
          catalogue_name: "Mjölk",
          provenance: "grocery_checkoff"
        })

      assert bought.expires_at == Date.add(Date.utc_today(), 12)
      assert bought.expires_source == "estimate"
    end

    test "clearing a date teaches nothing" do
      {:ok, item, :added, _} =
        Pantry.upsert_belief(home_scope(), %{
          catalogue_name: "Mjölk",
          provenance: "grocery_checkoff",
          shelf_life_days: 7
        })

      assert {:ok, %{expires_at: nil, expires_source: nil}} =
               Pantry.set_expiry(home_scope(), item.id, nil)

      assert Repo.get(Ingredient, item.ingredient_id, Tore.Scope.repo_opts(home_scope())).shelf_life_days ==
               7
    end

    test "a date already passed teaches nothing" do
      {:ok, item, :added, _} =
        Pantry.upsert_belief(home_scope(), %{
          catalogue_name: "Mjölk",
          provenance: "grocery_checkoff",
          shelf_life_days: 7
        })

      assert {:ok, _} = Pantry.set_expiry(home_scope(), item.id, Date.add(Date.utc_today(), -1))

      assert Repo.get(Ingredient, item.ingredient_id, Tore.Scope.repo_opts(home_scope())).shelf_life_days ==
               7
    end

    test "setting a date on an item that's gone says so" do
      assert Pantry.set_expiry(home_scope(), -1, ~D[2026-12-01]) == {:error, :not_found}
    end

    test "list_usable leaves out items past their date" do
      {:ok, _} = Pantry.add_item(home_scope(), %{name: "färsk", expires_at: Date.utc_today()})

      {:ok, _} =
        Pantry.add_item(home_scope(), %{
          name: "gammal",
          expires_at: Date.add(Date.utc_today(), -1)
        })

      {:ok, _} = Pantry.add_item(home_scope(), %{name: "utan datum"})

      assert Pantry.list_usable(home_scope()) |> Enum.map(& &1.name) |> Enum.sort() == [
               "färsk",
               "utan datum"
             ]
    end
  end

  describe "households" do
    test "a household sees only its own pantry" do
      other = scope_fixture(household_fixture())
      {:ok, _} = Pantry.add_item(home_scope(), %{name: "Mjölk"})
      {:ok, theirs} = Pantry.add_item(other, %{name: "Smör"})

      assert Enum.map(Pantry.list_inventory(home_scope()), & &1.name) == ["mjölk"]
      assert {:error, :not_found} = Pantry.find_by_name_fuzzy(home_scope(), "Smör")
      assert {:error, :not_found} = Pantry.remove_item(home_scope(), theirs.id)
      assert Enum.map(Pantry.list_inventory(other), & &1.name) == ["smör"]
    end
  end
end
