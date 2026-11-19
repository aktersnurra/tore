defmodule Tore.CostsTest do
  use Tore.DataCase, async: false

  alias Tore.Costs

  setup do
    user = user_fixture(name: "Tester")
    %{user_id: user.id}
  end

  test "log_receipt/1 inserts receipt and returns it", %{user_id: user_id} do
    attrs = %{
      date: Tore.Clock.today(),
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
      date: Tore.Clock.today(),
      user_id: user_id,
      total_amount: Decimal.new("20.00"),
      line_items: line_items
    }

    assert {:ok, receipt} = Costs.log_receipt(home_scope(), attrs)
    loaded = Tore.Repo.preload(receipt, :line_items)
    assert length(loaded.line_items) == 1
    assert hd(loaded.line_items).product_name == "Mjölk"
  end

  describe "a line's section" do
    setup %{user_id: user_id} do
      {:ok, receipt} =
        Costs.log_receipt(home_scope(), %{
          date: Tore.Clock.today(),
          user_id: user_id,
          total_amount: Decimal.new("60.00"),
          line_items: [
            %{product_name: "Laxfilé", total_price: Decimal.new("40.00"), category: "fish"},
            %{product_name: "Surdegsbröd", total_price: Decimal.new("20.00"), category: "bread"}
          ]
        })

      %{lines: Tore.Repo.preload(receipt, :line_items).line_items}
    end

    test "is one of the shop's sections", %{lines: lines} do
      assert Enum.map(lines, & &1.category) |> Enum.sort() == ["bread", "fish"]
    end

    test "can be moved to another section, not to one the shop doesn't have", %{lines: [lax | _]} do
      assert {:ok, %{category: "meat"}} = Costs.set_line_section(home_scope(), lax.id, "meat")
      assert {:error, %Ecto.Changeset{}} = Costs.set_line_section(home_scope(), lax.id, "Kött")
    end

    test "can't be moved from another household", %{lines: [lax | _]} do
      other = scope_fixture(household_fixture())
      assert {:error, :not_found} = Costs.set_line_section(other, lax.id, "meat")
    end
  end

  describe "spending" do
    setup %{user_id: user_id} do
      shop = fn week, total, lines ->
        {:ok, receipt} =
          Costs.log_receipt(home_scope(), %{
            date: week,
            week_start: week,
            store_name: "ICA",
            total_amount: Decimal.new(total),
            user_id: user_id,
            line_items:
              for {name, kr, section} <- lines do
                %{product_name: name, total_price: kr && Decimal.new(kr), category: section}
              end
          })

        receipt
      end

      w1 = ~D[2026-11-02]
      w2 = ~D[2026-11-09]

      shop.(w1, "300", [
        {"Kycklinglårfilé", "109", "meat"},
        {"Mjölk", "18", "dairy"},
        {"Lax", "80", "fish"}
      ])

      shop.(w2, "250", [{"kycklinglårfilé", "109", "meat"}, {"Gurka", nil, "produce"}])
      receipt = shop.(w2, "50", [{"Kaffe", "50", nil}])

      %{w1: w1, w2: w2, receipt: receipt}
    end

    test "per week, only weeks with receipts", %{w1: w1, w2: w2} do
      spent = Costs.spent_by_week(home_scope(), Date.add(w1, -7), w2)
      assert Map.keys(spent) |> Enum.sort(Date) == [w1, w2]
      assert Decimal.eq?(spent[w1], 300)
      assert Decimal.eq?(spent[w2], 300)
    end

    test "by section, biggest first, with what was bought most", %{w1: w1, w2: w2} do
      assert [meat, fish, other, dairy] = Costs.spending_by_section(home_scope(), w1, w2)

      # Names are one item however they were printed; a line without a price isn't counted.
      assert %{section: "meat", items: [%{name: "Kycklinglårfilé", times: 2, total: chicken}]} =
               meat

      assert Decimal.eq?(meat.total, 218) and Decimal.eq?(chicken, 218)
      assert {fish.section, other.section, dairy.section} == {"fish", "other", "dairy"}
      assert Decimal.eq?(other.total, 50)
    end

    test "one receipt, with its lines", %{receipt: receipt} do
      assert %{store_name: "ICA", line_items: [%{product_name: "Kaffe"}]} =
               Costs.get_receipt(home_scope(), receipt.id)

      assert Costs.get_receipt(scope_fixture(household_fixture()), receipt.id) == nil
    end
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
      today = Tore.Clock.today()

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
