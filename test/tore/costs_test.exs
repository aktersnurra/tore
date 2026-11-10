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

  # Marks the day of `date` as eating out in its week's plan.
  defp eat_out(scope, date, attrs) do
    plan_id = Tore.Streams.plan(scope, date)
    key = Enum.at(~w[mon tue wed thu fri sat sun], Date.day_of_week(date) - 1) <> "_dinner"
    {:ok, _} = Tore.Planning.eat_out(scope, plan_id, key, attrs)
  end

  test "eating_out_in_month/3 reads the month's days from the plans, newest first" do
    eat_out(home_scope(), ~D[2026-11-03], %{place: "Sushi", amount: 450})
    eat_out(home_scope(), ~D[2026-11-10], %{})
    eat_out(home_scope(), ~D[2026-10-31], %{amount: 100})

    assert [
             %{date: ~D[2026-11-10], place: nil, amount: nil},
             %{date: ~D[2026-11-03], place: "Sushi", amount: amount}
           ] = Costs.eating_out_in_month(home_scope(), 2026, 11)

    assert Decimal.equal?(amount, 450)
  end

  test "monthly_total/3 adds receipts and eating out, and ignores missing amounts", %{
    user_id: user_id
  } do
    {:ok, _} =
      Costs.log_receipt(home_scope(), %{
        date: ~D[2026-11-02],
        total_amount: "500",
        user_id: user_id
      })

    eat_out(home_scope(), ~D[2026-11-03], %{amount: 200})
    eat_out(home_scope(), ~D[2026-11-04], %{})

    assert Decimal.equal?(Costs.monthly_total(home_scope(), 2026, 11), 700)
  end

  describe "households" do
    test "receipts, eating out and totals stay in their household", %{user_id: user_id} do
      other = scope_fixture(household_fixture())
      today = Date.utc_today()

      {:ok, _} =
        Costs.log_receipt(other, %{date: today, total_amount: Decimal.new("99"), user_id: user_id})

      eat_out(other, today, %{amount: 200})

      assert Costs.recent_receipts(home_scope(), 10) == []
      assert Costs.eating_out_in_month(home_scope(), today.year, today.month) == []
      assert Decimal.equal?(Costs.monthly_total(home_scope(), today.year, today.month), 0)
      assert Decimal.equal?(Costs.monthly_total(other, today.year, today.month), 299)
    end
  end
end
