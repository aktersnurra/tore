defmodule Tore.CostsTest do
  use Tore.DataCase, async: false

  alias Tore.Costs

  setup do
    user = user_fixture(name: "Tester")
    %{user_id: user.id}
  end

  test "log_receipt/1 inserts receipt and returns it", %{user_id: user_id} do
    attrs = %{
      date: Date.utc_today(),
      store_name: "ICA",
      total_amount: Decimal.new("150.00"),
      user_id: user_id
    }

    assert {:ok, receipt} = Costs.log_receipt(home_scope(), attrs)
    assert receipt.store_name == "ICA"
  end

  test "log_receipt/1 inserts line items", %{user_id: user_id} do
    line_items = [
      %{
        product_name: "Mjölk",
        quantity: Decimal.new(2),
        unit_price: Decimal.new("10.00"),
        total_price: Decimal.new("20.00")
      }
    ]

    attrs = %{
      date: Date.utc_today(),
      user_id: user_id,
      total_amount: Decimal.new("20.00"),
      line_items: line_items
    }

    assert {:ok, receipt} = Costs.log_receipt(home_scope(), attrs)
    loaded = Tore.Repo.preload(receipt, :line_items)
    assert length(loaded.line_items) == 1
    assert hd(loaded.line_items).product_name == "Mjölk"
  end

  test "log_receipt/1 returns error on missing required fields" do
    assert {:error, _} = Costs.log_receipt(home_scope(), %{store_name: "ICA"})
  end

  describe "save_dining_out/1" do
    defp dining(user_id, attrs \\ %{}) do
      Map.merge(
        %{
          date: ~D[2026-11-10],
          plan_id: Tore.Streams.plan(home_scope(), ~D[2026-11-09]),
          slot_key: "tue_dinner",
          user_id: user_id
        },
        attrs
      )
    end

    test "stores an entry with no amount or place", %{user_id: user_id} do
      assert {:ok, entry} = Costs.save_dining_out(home_scope(), dining(user_id))
      assert entry.total_amount == nil
      assert entry.description == nil
    end

    test "stores an entry with an amount", %{user_id: user_id} do
      attrs = dining(user_id, %{description: "Sushi", total_amount: "450.50"})
      assert {:ok, entry} = Costs.save_dining_out(home_scope(), attrs)
      assert Decimal.equal?(entry.total_amount, Decimal.new("450.50"))
    end

    test "a later call fills in the same entry and keeps the rest", %{user_id: user_id} do
      {:ok, first} = Costs.save_dining_out(home_scope(), dining(user_id, %{description: "Sushi"}))

      {:ok, second} =
        Costs.save_dining_out(
          home_scope(),
          dining(user_id, %{description: nil, total_amount: 400})
        )

      assert second.id == first.id
      assert second.description == "Sushi"
      assert Decimal.equal?(second.total_amount, 400)
    end

    test "an empty string clears a field", %{user_id: user_id} do
      {:ok, _} =
        Costs.save_dining_out(
          home_scope(),
          dining(user_id, %{description: "Sushi", total_amount: 400})
        )

      {:ok, entry} =
        Costs.save_dining_out(home_scope(), dining(user_id, %{description: "", total_amount: ""}))

      assert entry.description == nil
      assert entry.total_amount == nil
    end

    test "refuses a negative or unreadable amount", %{user_id: user_id} do
      assert {:error, _} =
               Costs.save_dining_out(home_scope(), dining(user_id, %{total_amount: -1}))

      assert {:error, _} =
               Costs.save_dining_out(home_scope(), dining(user_id, %{total_amount: "lots"}))
    end
  end

  test "dining_out_in_month/2 only returns that month", %{user_id: user_id} do
    {:ok, _} =
      Costs.save_dining_out(home_scope(), %{
        date: ~D[2026-11-10],
        plan_id: "p",
        slot_key: "a",
        user_id: user_id
      })

    {:ok, _} =
      Costs.save_dining_out(home_scope(), %{
        date: ~D[2026-10-10],
        plan_id: "p",
        slot_key: "b",
        user_id: user_id
      })

    assert [%{date: ~D[2026-11-10]}] = Costs.dining_out_in_month(home_scope(), 2026, 11)
  end

  test "monthly_total/2 adds receipts and eating out, and ignores missing amounts", %{
    user_id: user_id
  } do
    {:ok, _} =
      Costs.log_receipt(home_scope(), %{
        date: ~D[2026-11-02],
        total_amount: "500",
        user_id: user_id
      })

    {:ok, _} =
      Costs.save_dining_out(home_scope(), %{
        date: ~D[2026-11-03],
        plan_id: "p",
        slot_key: "a",
        total_amount: 200,
        user_id: user_id
      })

    {:ok, _} =
      Costs.save_dining_out(home_scope(), %{
        date: ~D[2026-11-04],
        plan_id: "p",
        slot_key: "b",
        user_id: user_id
      })

    assert Decimal.equal?(Costs.monthly_total(home_scope(), 2026, 11), 700)
  end

  describe "households" do
    test "receipts, eating out and totals stay in their household", %{user_id: user_id} do
      other = scope_fixture(household_fixture())
      today = Date.utc_today()
      plan_id = Tore.Streams.plan(other, today)

      {:ok, _} =
        Costs.log_receipt(other, %{date: today, total_amount: Decimal.new("99"), user_id: user_id})

      {:ok, _} =
        Costs.save_dining_out(other, %{
          plan_id: plan_id,
          slot_key: "mon_dinner",
          date: today,
          total_amount: Decimal.new("200"),
          user_id: user_id
        })

      assert Costs.recent_receipts(home_scope(), 10) == []
      assert Costs.dining_out_in_month(home_scope(), today.year, today.month) == []
      assert Costs.get_dining_out(home_scope(), plan_id, "mon_dinner") == nil
      assert Decimal.equal?(Costs.monthly_total(home_scope(), today.year, today.month), 0)
      assert Decimal.equal?(Costs.monthly_total(other, today.year, today.month), 299)
    end
  end
end
