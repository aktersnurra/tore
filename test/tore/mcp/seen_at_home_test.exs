defmodule Tore.Mcp.SeenAtHomeTest do
  @moduledoc "pi reading a photo of a shelf or the fridge: add_to_pantry with `seen`."
  use Tore.DataCase, async: false

  alias Tore.{Mcp, Pantry}
  alias Tore.Harness.Runs
  alias Tore.Pantry.PantryItem

  # What pi sends for one item it saw.
  defp seen(name, extra \\ %{}) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "add_to_pantry",
        "arguments" => Map.merge(%{"name" => name, "seen" => true}, extra)
      }
    }

    {:reply, %{"result" => result}} = Mcp.handle(home_scope(), request)
    result
  end

  defp run_id(%{"isError" => false, "structuredContent" => %{run_id: id}}), do: id

  defp row(name), do: Repo.get_by!(PantryItem, [name: name], Tore.Scope.repo_opts(home_scope()))

  defp manual(name, attrs \\ %{}) do
    {:ok, _, :added, _} =
      Pantry.upsert_belief(home_scope(), Map.merge(%{name: name, provenance: "manual"}, attrs))
  end

  test "what's seen goes in, and seen again its quantity is what's there now" do
    seen("mjölk", %{"quantity" => 2, "unit" => "l"})
    seen("mjölk", %{"quantity" => 1, "unit" => "l"})

    assert Decimal.equal?(row("mjölk").quantity, 1)
  end

  test "seen with no quantity keeps the one we know" do
    manual("mjöl", %{quantity: Decimal.new(2), unit: "kg"})
    seen("mjöl")

    assert Decimal.equal?(row("mjöl").quantity, 2)
    assert row("mjöl").unit == "kg"
  end

  test "ticks and manual adds still add to the quantity" do
    attrs = %{name: "mjöl", quantity: Decimal.new(1), unit: "kg", provenance: "grocery_checkoff"}
    {:ok, _, :added, _} = Pantry.upsert_belief(home_scope(), attrs)
    {:ok, _, :bumped, _} = Pantry.upsert_belief(home_scope(), attrs)

    assert Decimal.equal?(row("mjöl").quantity, 2)
  end

  test "undo puts back the quantity, also one that was unknown" do
    manual("mjölk", %{quantity: Decimal.new(1), unit: "l"})
    manual("grädde")

    first = run_id(seen("mjölk", %{"quantity" => 3, "unit" => "l"}))
    second = run_id(seen("grädde", %{"quantity" => 2, "unit" => "dl"}))

    assert {:ok, _} = Runs.revert(home_scope(), first)
    assert {:ok, _} = Runs.revert(home_scope(), second)

    assert Decimal.equal?(row("mjölk").quantity, 1)
    assert row("grädde").quantity == nil
  end

  describe "how long it keeps" do
    test "with no printed date, the guess sets one" do
      seen("mjölk", %{"keeps_days" => 7})

      assert row("mjölk").expires_at == Date.add(Tore.Clock.today(), 7)
      assert row("mjölk").expires_source == "estimate"
    end

    test "a printed date beats the guess" do
      seen("mjölk", %{"keeps_days" => 7, "best_before" => "2026-12-24"})

      assert row("mjölk").expires_at == ~D[2026-12-24]
      assert row("mjölk").expires_source == "label"
    end

    test "a date that isn't one is refused, and nothing is written" do
      assert %{"isError" => true} = seen("mjölk", %{"best_before" => "snart"})
      assert Pantry.list_inventory(home_scope()) == []
    end

    test "seen again doesn't make it fresher" do
      seen("mjölk", %{"keeps_days" => 7})

      {:ok, _} =
        row("mjölk") |> Ecto.Changeset.change(expires_at: ~D[2026-11-06]) |> Repo.update()

      seen("mjölk", %{"keeps_days" => 7})

      assert row("mjölk").expires_at == ~D[2026-11-06]
    end

    test "undo restores the date, or clears one the item didn't have" do
      manual("mjölk")
      {:ok, _} = Pantry.set_expiry(home_scope(), row("mjölk").id, ~D[2026-12-01])

      {:ok, _} =
        row("mjölk") |> Ecto.Changeset.change(expires_source: "estimate") |> Repo.update()

      manual("ost")

      dated = run_id(seen("mjölk", %{"best_before" => "2027-02-02"}))
      assert row("mjölk").expires_at == ~D[2027-02-02]
      guessed = run_id(seen("ost", %{"keeps_days" => 20}))

      assert {:ok, _} = Runs.revert(home_scope(), dated)
      assert {:ok, _} = Runs.revert(home_scope(), guessed)

      assert row("mjölk").expires_at == ~D[2026-12-01]
      assert row("mjölk").expires_source == "estimate"
      assert row("ost").expires_at == nil
    end
  end
end
