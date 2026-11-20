defmodule Tore.PantryTest do
  use Tore.DataCase, async: false

  alias Tore.Pantry

  test "add_item/1 inserts and returns pantry item" do
    assert {:ok, item} =
             Pantry.add_item(home_scope(), %{name: "Mjölk", quantity: Decimal.new(2), unit: "L"})

    assert item.name == "mjölk"
    assert item.added_at == Tore.Clock.today()
  end

  test "add_item/1 defaults added_at to today when omitted" do
    assert {:ok, item} = Pantry.add_item(home_scope(), %{name: "Smör"})
    assert item.added_at == Tore.Clock.today()
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

  describe "how sure Tore is, as days go by" do
    alias Tore.Pantry.PantryItem

    @now ~U[2026-06-29 12:00:00Z]

    defp belief(belief, days_ago, half_life_days \\ nil) do
      PantryItem.effective_belief(
        %PantryItem{
          belief: belief,
          last_seen_at: DateTime.add(@now, -days_ago, :day),
          half_life_days: half_life_days
        },
        @now,
        DateTime.to_date(@now)
      )
    end

    test "what's only cooked with keeps its belief however long ago it was seen" do
      assert belief("confirmed", 200) == :confirmed
      assert belief("probable", 200) == :probable
    end

    test "a basic is eaten between dinners: unsure after one of its rhythm, gone after two" do
      assert belief("confirmed", 4, 5) == :confirmed
      assert belief("probable", 4, 5) == :probable
      assert belief("confirmed", 5, 5) == :uncertain
      assert belief("confirmed", 9, 5) == :uncertain
      assert belief("confirmed", 10, 5) == :missing
    end
  end

  test "a basic's row carries its rhythm, and is counted gone once it's likely eaten" do
    :ok = Tore.Basics.ask(home_scope(), [%{name: "Mjölk"}])

    {:ok, milk, _, _} =
      Pantry.upsert_belief(home_scope(), %{catalogue_name: "Mjölk", provenance: "manual"})

    {:ok, _, _, _} =
      Pantry.upsert_belief(home_scope(), %{catalogue_name: "Spaghetti", provenance: "manual"})

    weeks_ago = DateTime.utc_now() |> DateTime.add(-15, :day) |> DateTime.truncate(:second)

    for item <- Pantry.list_inventory(home_scope()),
        do: item |> Ecto.Changeset.change(last_seen_at: weeks_ago) |> Tore.Repo.update!()

    assert %{"mjölk" => 7, "spaghetti" => nil} =
             Map.new(Pantry.list_inventory(home_scope()), &{&1.name, &1.half_life_days})

    assert Pantry.at_home(home_scope(), ["mjölk", "spaghetti"]).missing == ["mjölk"]

    {:ok, _} = Pantry.confirm_item(home_scope(), milk.id)
    assert Pantry.at_home(home_scope(), ["mjölk"]).missing == []
  end

  describe "Slut teaches how fast it goes" do
    defp bought_days_ago(item, days) do
      item
      |> Ecto.Changeset.change(added_at: Date.add(Tore.Clock.today(), -days))
      |> Tore.Repo.update!()
    end

    defp ingredient(item),
      do:
        Tore.Repo.get!(
          Tore.Recipes.Ingredient,
          item.ingredient_id,
          Tore.Scope.repo_opts(home_scope())
        )

    test "a regular buy's rhythm moves halfway to how long the pack lasted" do
      :ok = Tore.Basics.ask(home_scope(), [%{name: "Mjölk"}])
      {:ok, milk, _, _} = Pantry.upsert_belief(home_scope(), %{catalogue_name: "Mjölk"})
      bought_days_ago(milk, 3)

      {:ok, _} = Pantry.mark_gone(home_scope(), milk.id)

      assert [%{basic: %{interval_days: 5}}] = Tore.Basics.list(home_scope())
      # Already gone, a second Slut teaches nothing.
      {:ok, _} = Pantry.mark_gone(home_scope(), milk.id)
      assert [%{basic: %{interval_days: 5}}] = Tore.Basics.list(home_scope())
    end

    test "something else eaten between meals learns its own days, which then set its half-life" do
      {:ok, yoghurt, _, _} = Pantry.upsert_belief(home_scope(), %{catalogue_name: "Yoghurt"})

      {:ok, _} =
        yoghurt |> ingredient() |> Ecto.Changeset.change(lasts: "week") |> Tore.Repo.update()

      bought_days_ago(yoghurt, 13)

      {:ok, _} = Pantry.mark_gone(home_scope(), yoghurt.id)

      assert ingredient(yoghurt).lasts_days == 10
      assert [%{half_life_days: 10}] = Pantry.list_inventory(home_scope())
    end

    test "what's only for cooking learns nothing from running out" do
      {:ok, pasta, _, _} = Pantry.upsert_belief(home_scope(), %{catalogue_name: "Pasta"})

      {:ok, _} =
        pasta |> ingredient() |> Ecto.Changeset.change(lasts: "cooking") |> Tore.Repo.update()

      bought_days_ago(pasta, 30)

      {:ok, _} = Pantry.mark_gone(home_scope(), pasta.id)

      assert ingredient(pasta).lasts_days == nil
    end
  end

  test "PantryItem.effective_belief/3 leaves uncertain and missing untouched" do
    now = ~U[2026-06-29 12:00:00Z]
    ancient = ~U[2024-01-01 00:00:00Z]
    uncertain = %Tore.Pantry.PantryItem{belief: "uncertain", last_seen_at: ancient}
    missing = %Tore.Pantry.PantryItem{belief: "missing", last_seen_at: ancient}

    assert Tore.Pantry.PantryItem.effective_belief(uncertain, now, DateTime.to_date(now)) ==
             :uncertain

    assert Tore.Pantry.PantryItem.effective_belief(missing, now, DateTime.to_date(now)) ==
             :missing
  end

  test "PantryItem.effective_belief/3 with no last_seen_at returns stored belief" do
    item = %Tore.Pantry.PantryItem{belief: "confirmed", last_seen_at: nil}

    assert Tore.Pantry.PantryItem.effective_belief(item, ~U[2026-06-29 12:00:00Z], ~D[2026-06-29]) ==
             :confirmed
  end

  test "list_inventory_by_belief/0 groups by *effective* belief, not stored" do
    :ok = Tore.Basics.ask(home_scope(), [%{name: "Old milk"}])

    {:ok, item, _, _} =
      Pantry.upsert_belief(home_scope(), %{catalogue_name: "Old milk", provenance: "vision"})

    # A week and a half ago: past one rhythm of a weekly basic, not two, so unsure.
    backdated = DateTime.utc_now() |> DateTime.add(-10, :day) |> DateTime.truncate(:second)

    item
    |> Ecto.Changeset.change(last_seen_at: backdated)
    |> Tore.Repo.update!()

    groups = Pantry.list_inventory_by_belief(home_scope())
    assert {:uncertain, [decayed]} = Enum.find(groups, fn {b, _} -> b == :uncertain end)
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
        now,
        DateTime.to_date(now)
      )
    end

    test "with a date, an item keeps its belief until the date" do
      assert seen("confirmed", 3, ~D[2027-01-01]) == :confirmed
      assert seen("confirmed", 200, ~D[2027-01-01]) == :confirmed
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

    test "with no date and no rhythm, nothing decays" do
      assert seen("confirmed", 15, nil) == :confirmed
      assert seen("confirmed", 31, nil) == :confirmed
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

      assert item.expires_at == Date.add(Tore.Clock.today(), 7)
      assert item.expires_source == "estimate"
    end

    test "a new guess doesn't overwrite the shelf life we have" do
      attrs = %{catalogue_name: "Mjölk", provenance: "grocery_checkoff"}

      {:ok, _item, :added, _} =
        Pantry.upsert_belief(home_scope(), Map.put(attrs, :shelf_life_days, 7))

      {:ok, item, :bumped, _} =
        Pantry.upsert_belief(home_scope(), Map.put(attrs, :shelf_life_days, 30))

      assert Repo.get(Ingredient, item.ingredient_id, Tore.Scope.repo_opts(home_scope())).shelf_life_days ==
               7

      assert item.expires_at == Date.add(Tore.Clock.today(), 7)
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

      chosen = Date.add(Tore.Clock.today(), 12)
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

      assert bought.expires_at == Date.add(Tore.Clock.today(), 12)
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

      assert {:ok, _} = Pantry.set_expiry(home_scope(), item.id, Date.add(Tore.Clock.today(), -1))

      assert Repo.get(Ingredient, item.ingredient_id, Tore.Scope.repo_opts(home_scope())).shelf_life_days ==
               7
    end

    test "setting a date on an item that's gone says so" do
      assert Pantry.set_expiry(home_scope(), -1, ~D[2026-12-01]) == {:error, :not_found}
    end

    test "list_usable leaves out items past their date" do
      {:ok, _} = Pantry.add_item(home_scope(), %{name: "färsk", expires_at: Tore.Clock.today()})

      {:ok, _} =
        Pantry.add_item(home_scope(), %{
          name: "gammal",
          expires_at: Date.add(Tore.Clock.today(), -1)
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

  describe "at_home/2" do
    test "splits a dish's ingredients into what's at home and what's missing, in order" do
      {:ok, _} = Pantry.add_item(home_scope(), %{name: "Vetemjöl"})
      {:ok, _} = Pantry.add_item(home_scope(), %{name: "Smör"})

      assert Pantry.at_home(home_scope(), ["vetemjöl", "Kanel", "smör", "Kardemumma"]) ==
               %{have: ["vetemjöl", "smör"], missing: ["Kanel", "Kardemumma"], unsure: []}
    end

    test "says which of what's at home Tore is unsure of, with the row and when it was seen" do
      :ok = Tore.Basics.ask(home_scope(), [%{name: "Mjölk"}])
      {:ok, milk, _, _} = Pantry.upsert_belief(home_scope(), %{catalogue_name: "Mjölk"})
      {:ok, _} = Pantry.add_item(home_scope(), %{name: "Smör"})
      seen = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      {:ok, _} = milk |> Ecto.Changeset.change(last_seen_at: seen) |> Tore.Repo.update()

      assert %{have: ["Mjölk", "smör"], missing: [], unsure: [unsure]} =
               Pantry.at_home(home_scope(), ["Mjölk", "smör"])

      assert unsure == %{name: "Mjölk", id: milk.id, last_seen_at: seen}
    end

    test "water, salt and pepper are taken as always at home" do
      assert Pantry.at_home(home_scope(), ["Vatten", "salt", "svartpeppar", "jäst"]) ==
               %{have: ["Vatten", "salt", "svartpeppar"], missing: ["jäst"], unsure: []}
    end
  end

  describe "use_up/2" do
    test "a dinner uses up what it took, not what outlasts it; buying it again brings it back" do
      buy = fn name, category ->
        {:ok, _, _, _} =
          Pantry.upsert_belief(home_scope(), %{
            catalogue_name: name,
            category: category,
            quantity: Decimal.new(1),
            provenance: "receipt"
          })
      end

      buy.("Lax", "meat")
      buy.("Vetemjöl", "dry_goods")
      buy.("Grädde", "dairy")

      used = Pantry.use_up(home_scope(), uses(["lax", "vetemjöl", "dill"]))

      assert Enum.map(used, & &1.name) == ["lax"]
      assert Pantry.at_home(home_scope(), ["lax", "vetemjöl", "grädde"]).missing == ["lax"]

      :ok = Pantry.put_back(home_scope(), used)
      assert Pantry.at_home(home_scope(), ["lax"]).missing == []

      Pantry.use_up(home_scope(), uses(["lax"]))
      buy.("Lax", "meat")
      assert Pantry.at_home(home_scope(), ["lax"]).missing == []
    end

    test "a dinner takes its amounts off what's at home, in any unit of the same kind" do
      have = fn name, category, quantity, unit ->
        {:ok, _, _, _} =
          Pantry.upsert_belief(home_scope(), %{
            catalogue_name: name,
            category: category,
            quantity: Decimal.new(quantity),
            unit: unit,
            provenance: "manual"
          })
      end

      have.("Spaghetti", "dry_goods", "1", "kg")
      have.("Mjölk", "dairy", "1", "l")
      have.("Ägg", "dairy", "6", "st")

      used =
        Pantry.use_up(home_scope(), [
          %{name: "spaghetti", quantity: Decimal.new(500), unit: "g"},
          %{name: "mjölk", quantity: Decimal.new(1), unit: "dl"},
          # A count and a weight don't compare: what's fresh is taken as used up.
          %{name: "ägg", quantity: Decimal.new(100), unit: "g"}
        ])

      left = fn -> Map.new(Pantry.list_inventory(home_scope()), &{&1.name, &1}) end

      assert %{quantity: half, unit: "kg", belief: "confirmed"} = left.()["spaghetti"]
      assert Decimal.equal?(half, "0.5")
      assert Decimal.equal?(left.()["mjölk"].quantity, "0.9")
      assert left.()["ägg"].belief == "missing"

      :ok = Pantry.put_back(home_scope(), used)
      assert Decimal.equal?(left.()["spaghetti"].quantity, 1)
      assert left.()["ägg"].belief == "confirmed"

      # More than there is: it's gone.
      Pantry.use_up(home_scope(), [%{name: "spaghetti", quantity: Decimal.new(1200), unit: "g"}])
      assert Pantry.at_home(home_scope(), ["spaghetti"]).missing == ["spaghetti"]
    end

    defp uses(names), do: Enum.map(names, &%{name: &1, quantity: nil, unit: nil})
  end

  describe "Hemma: putting away, still there, gone" do
    test "put_away/4 adds a confirmed row, under a known ingredient's name and category" do
      {:ok, _, :added, nil} =
        Pantry.upsert_belief(home_scope(), %{
          catalogue_name: "Mjölk",
          category: "dairy",
          provenance: "receipt"
        })

      {:ok, _} = Pantry.mark_gone(home_scope(), hd(Pantry.list_inventory(home_scope())).id)

      {:ok, item} = Pantry.put_away(home_scope(), "mjölk", Decimal.new(1), "l")

      assert item.name == "mjölk"
      assert item.category == "dairy"
      assert item.belief == "confirmed"
      assert [_one] = Pantry.list_inventory(home_scope())
    end

    test "confirm_item/2 makes an unsure row sure again, and drops a date it outlived" do
      {:ok, item} =
        Pantry.add_item(home_scope(), %{
          name: "Smör",
          belief: "uncertain",
          expires_at: Date.add(Tore.Clock.today(), -2),
          expires_source: "estimate"
        })

      {:ok, item} = Pantry.confirm_item(home_scope(), item.id)

      assert item.belief == "confirmed"
      assert item.expires_at == nil

      assert Pantry.PantryItem.effective_belief(item, DateTime.utc_now(), Tore.Clock.today()) ==
               :confirmed
    end

    test "mark_gone/2 makes a row missing, so it isn't counted as at home" do
      {:ok, item} = Pantry.add_item(home_scope(), %{name: "Ägg"})
      {:ok, _} = Pantry.mark_gone(home_scope(), item.id)

      assert Pantry.at_home(home_scope(), ["ägg"]).missing == ["ägg"]
    end

    test "another household's row can't be changed" do
      other = Tore.AccountsFixtures.scope_fixture(Tore.AccountsFixtures.household_fixture())
      {:ok, item} = Pantry.add_item(home_scope(), %{name: "Ägg"})

      assert {:error, :not_found} = Pantry.mark_gone(other, item.id)
      assert {:error, :not_found} = Pantry.confirm_item(other, item.id)
    end
  end

  describe "pictures" do
    setup do
      {:ok, item, :added, nil} =
        Pantry.upsert_belief(home_scope(), %{catalogue_name: "Mjölk", category: "dairy"})

      %{
        ingredient:
          Tore.Repo.get!(
            Tore.Recipes.Ingredient,
            item.ingredient_id,
            Tore.Scope.repo_opts(home_scope())
          )
      }
    end

    test "a photo from the household replaces the scanned one, and the old file goes", %{
      ingredient: ingredient
    } do
      scope = home_scope()
      url = "https://images.openfoodfacts.org/images/products/1/front_sv.1.200.jpg"
      Mox.expect(Tore.MockHTTP, :fetch, fn ^url -> {:ok, "scanned"} end)
      :ok = Pantry.keep_picture(scope, ingredient, url)
      old = Tore.Repo.reload!(ingredient, Tore.Scope.repo_opts(scope)).image_path

      assert :ok = Pantry.put_picture(scope, ingredient.id, "ours")

      assert {:ok, "ours"} = Pantry.picture(scope, ingredient.id)

      assert {:error, :not_found} =
               Tore.Storage.client().get_object(Tore.Storage.Buckets.recipes(), old)

      # A later scan leaves ours alone.
      fresh = Tore.Repo.reload!(ingredient, Tore.Scope.repo_opts(scope))
      assert :ok = Pantry.keep_picture(scope, fresh, url)
      assert {:ok, "ours"} = Pantry.picture(scope, ingredient.id)
    end

    test "another household's ingredient can't be given a photo", %{ingredient: ingredient} do
      other = Tore.AccountsFixtures.scope_fixture(Tore.AccountsFixtures.household_fixture())
      assert {:error, :not_found} = Pantry.put_picture(other, ingredient.id, "ours")
    end
  end
end
