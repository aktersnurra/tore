defmodule Tore.Capture.ShelfPhotoTest do
  use Tore.DataCase, async: false
  import Mox
  setup :verify_on_exit!

  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.PantryBeliefUpdate
  alias Tore.Harness.Kinds.PantryUpdate
  alias Tore.Pantry
  alias Tore.Pantry.PantryItem

  @usage %{prompt_tokens: 0, completion_tokens: 0, cost_usd: 0}

  defp item(name, quantity \\ nil, unit \\ nil) do
    %{"name" => name, "quantity" => quantity, "unit" => unit, "category" => "other"}
  end

  # The vision call, then name matching. `matches` maps a raw name to the
  # catalogue name it resolves to; anything else resolves to itself.
  defp expect_photo(items, matches \\ %{}) do
    expect(Tore.MockLLM, :vision, fn _blobs, _system, _user, _opts ->
      {:ok, %{"items" => items}, @usage}
    end)

    expect(Tore.MockLLM, :text, fn _system, _user, _opts ->
      norm =
        Enum.map(items, fn %{"name" => name} ->
          catalogue_name = Map.get(matches, name, name)

          %{
            "raw_name" => name,
            "catalogue_name" => catalogue_name,
            "category" => "other",
            "default_unit" => nil,
            "matched_key" => nil
          }
        end)

      {:ok, %{"items" => norm}, @usage}
    end)
  end

  defp photo(n), do: <<255, 216, 255, n>>

  # A shelf photo read into the pantry, as its run.
  defp shelf(image) do
    {:ok, run} =
      Runs.start(home_scope(), PantryUpdate, %{channel: :shelf_photo, image_binary: image})

    run
  end

  defp read_names(%KitchenRun{artifacts: artifacts}) do
    %PantryBeliefUpdate{items: items} = Enum.find(artifacts, &match?(%PantryBeliefUpdate{}, &1))
    Enum.map(items, & &1.name)
  end

  defp row(name), do: Repo.get_by!(PantryItem, [name: name], Tore.Scope.repo_opts(home_scope()))

  test "a photo with five items applies straight away" do
    names = ~w(mjölk ägg smör ost salt)
    expect_photo(Enum.map(names, &item/1))

    run = shelf(photo(1))

    assert %KitchenRun{status: :applied} = Runs.get(home_scope(), run.id)
    assert Enum.sort(read_names(run)) == Enum.sort(names)

    assert Enum.map(Pantry.list_inventory(home_scope()), & &1.name) |> Enum.sort() ==
             Enum.sort(names)
  end

  test "a photo keeps no copy of the image" do
    expect_photo([item("mjölk")])

    run = shelf(photo(1))

    %KitchenRun{status: :applied, input: input} = Runs.get(home_scope(), run.id)
    assert (input[:image_path] || input["image_path"]) == nil
  end

  test "a second photo replaces the quantity instead of adding to it" do
    expect_photo([item("mjölk", 2, "l")])
    shelf(photo(1))

    expect_photo([item("mjölk", 2, "l")])
    shelf(photo(2))

    assert Decimal.equal?(row("mjölk").quantity, 2)
  end

  test "a photo with no readable quantity keeps the one we know" do
    {:ok, _, :added, _} =
      Pantry.upsert_belief(home_scope(), %{
        name: "mjöl",
        quantity: Decimal.new(2),
        unit: "kg",
        provenance: "manual"
      })

    expect_photo([item("mjöl")])
    shelf(photo(1))

    assert Decimal.equal?(row("mjöl").quantity, 2)
    assert row("mjöl").unit == "kg"
  end

  test "ticks and manual adds still add to the quantity" do
    attrs = %{name: "mjöl", quantity: Decimal.new(1), unit: "kg", provenance: "grocery_checkoff"}
    {:ok, _, :added, _} = Pantry.upsert_belief(home_scope(), attrs)
    {:ok, _, :bumped, _} = Pantry.upsert_belief(home_scope(), attrs)

    assert Decimal.equal?(row("mjöl").quantity, 2)
  end

  test "undo removes new items and restores the ones the photo changed" do
    {:ok, _, :added, _} =
      Pantry.upsert_belief(home_scope(), %{
        name: "mjölk",
        quantity: Decimal.new(1),
        unit: "l",
        provenance: "manual"
      })

    expect_photo([item("mjölk", 3, "l"), item("ägg", 6, "st")])
    run = shelf(photo(1))
    assert Decimal.equal?(row("mjölk").quantity, 3)

    assert {:ok, _} = Runs.revert(home_scope(), run.id)

    assert Decimal.equal?(row("mjölk").quantity, 1)
    assert Repo.get_by(PantryItem, [name: "ägg"], Tore.Scope.repo_opts(home_scope())) == nil
  end

  test "undo restores a quantity that was unknown before the photo" do
    {:ok, _, :added, _} =
      Pantry.upsert_belief(home_scope(), %{name: "mjölk", provenance: "manual"})

    expect_photo([item("mjölk", 3, "l")])
    run = shelf(photo(1))

    assert {:ok, _} = Runs.revert(home_scope(), run.id)

    assert row("mjölk").quantity == nil
    assert row("mjölk").unit == nil
  end

  test "undo is right when two lines in a photo are the same ingredient" do
    {:ok, _, :added, _} =
      Pantry.upsert_belief(home_scope(), %{
        name: "mjölk",
        quantity: Decimal.new(1),
        unit: "l",
        provenance: "manual"
      })

    expect_photo([item("mjölk", 3, "l"), item("mellanmjölk", 2, "l")], %{"mellanmjölk" => "mjölk"})

    run = shelf(photo(1))

    assert {:ok, _} = Runs.revert(home_scope(), run.id)

    assert Decimal.equal?(row("mjölk").quantity, 1)
  end

  test "a photo with nothing in it makes no name-matching call and changes nothing" do
    expect(Tore.MockLLM, :vision, fn _blobs, _system, _user, _opts ->
      {:ok, %{"items" => []}, @usage}
    end)

    assert read_names(shelf(photo(1))) == []
    assert Pantry.list_inventory(home_scope()) == []
  end

  describe "shelf life" do
    defp expect_guess(name, days, printed \\ nil) do
      expect(Tore.MockLLM, :vision, fn _blobs, _system, _user, _opts ->
        {:ok, %{"items" => [item(name) |> Map.put("expires_on", printed)]}, @usage}
      end)

      expect(Tore.MockLLM, :text, fn _system, _user, _opts ->
        {:ok,
         %{
           "items" => [
             %{
               "raw_name" => name,
               "catalogue_name" => name,
               "category" => "other",
               "default_unit" => nil,
               "matched_key" => nil,
               "shelf_life_days" => days
             }
           ]
         }, @usage}
      end)
    end

    test "with no printed date, the guess sets one" do
      expect_guess("mjölk", 7)
      shelf(photo(1))

      assert row("mjölk").expires_at == Date.add(Tore.Clock.today(), 7)
      assert row("mjölk").expires_source == "estimate"
    end

    test "a printed date beats the guess" do
      expect_guess("mjölk", 7, "2026-12-24")
      shelf(photo(1))

      assert row("mjölk").expires_at == ~D[2026-12-24]
      assert row("mjölk").expires_source == "label"
    end

    test "a guess that makes no sense and a date that can't be read leave no date" do
      expect_guess("mjölk", 99_999, "snart")
      shelf(photo(1))

      assert row("mjölk").expires_at == nil

      assert Repo.get!(
               Tore.Recipes.Ingredient,
               row("mjölk").ingredient_id,
               Tore.Scope.repo_opts(home_scope())
             ).shelf_life_days == nil
    end

    test "a second photo doesn't make an item fresher" do
      expect_guess("mjölk", 7)
      shelf(photo(1))

      {:ok, _} =
        row("mjölk") |> Ecto.Changeset.change(expires_at: ~D[2026-11-06]) |> Repo.update()

      expect_guess("mjölk", 7)
      shelf(photo(2))

      assert row("mjölk").expires_at == ~D[2026-11-06]
    end

    test "undo restores the date" do
      {:ok, _, :added, _} =
        Pantry.upsert_belief(home_scope(), %{name: "mjölk", provenance: "manual"})

      {:ok, _} = Pantry.set_expiry(home_scope(), row("mjölk").id, ~D[2026-12-01])

      {:ok, _} =
        row("mjölk") |> Ecto.Changeset.change(expires_source: "estimate") |> Repo.update()

      expect_guess("mjölk", 7, "2027-02-02")
      run = shelf(photo(1))
      assert row("mjölk").expires_at == ~D[2027-02-02]

      assert {:ok, _} = Runs.revert(home_scope(), run.id)

      assert row("mjölk").expires_at == ~D[2026-12-01]
      assert row("mjölk").expires_source == "estimate"
    end

    test "undo clears a date the item didn't have before" do
      {:ok, _, :added, _} =
        Pantry.upsert_belief(home_scope(), %{name: "mjölk", provenance: "manual"})

      expect_guess("mjölk", 7)
      run = shelf(photo(1))
      assert {:ok, _} = Runs.revert(home_scope(), run.id)

      assert row("mjölk").expires_at == nil
      assert row("mjölk").expires_source == nil
    end
  end
end
