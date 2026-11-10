defmodule Tore.Capture.DeleteTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Costs, Recipes, Shop, Streams}
  alias Tore.Capture.{Dispatch, Router}

  setup :verify_on_exit!

  @usage %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}

  setup do
    Gettext.put_locale(ToreWeb.Gettext, "sv")
    user = user_fixture()
    %{ctx: %{household_id: home_scope().household_id, user_id: user.id}, user: user}
  end

  test "remove_shopping_item takes the item off this week's list", %{ctx: ctx} do
    stub(Tore.MockLLM, :text, fn _, _, _ -> {:ok, %{"section" => "dairy"}, @usage} end)
    list_id = Streams.shop_list(home_scope(), Date.utc_today())
    {:ok, _} = Shop.add_item(home_scope(), list_id, "mjölk", nil, nil, nil)

    bubble = Dispatch.remove_shopping_item("mjölk", ctx)

    assert bubble.text =~ "mjölk"
    assert {:ok, %{items: items}} = Shop.load_list(home_scope(), list_id)
    assert items == %{}
  end

  test "delete_recipe deletes it, and says so when there's none", %{ctx: ctx} do
    {:ok, soup} = Recipes.create(home_scope(), %{title: "Soppa", base_servings: 4}, image: false)

    assert Dispatch.delete_recipe(soup.id, ctx).text =~ "Soppa"
    assert Recipes.get(home_scope(), soup.id) == nil
    refute Dispatch.delete_recipe(soup.id, ctx).text =~ "Soppa"
  end

  test "the model lists receipts, then deletes the one asked for", %{ctx: ctx, user: user} do
    {:ok, ica} =
      Costs.log_receipt(home_scope(), %{
        date: ~D[2026-11-02],
        store_name: "ICA",
        total_amount: "500",
        user_id: user.id
      })

    {:ok, coop} =
      Costs.log_receipt(home_scope(), %{
        date: ~D[2026-11-03],
        store_name: "Coop",
        total_amount: "200",
        user_id: user.id
      })

    list = %{id: "c1", name: "list_receipts", args: %{}}

    Tore.MockLLM
    |> expect(:chat_with_tools, fn _, _, _, _ -> {:ok, {:tool_calls, [list]}, @usage} end)
    |> expect(:chat_with_tools, fn _, msgs, _, _ ->
      %{"receipts" => receipts} = Jason.decode!(List.last(msgs).content)
      %{"id" => id} = Enum.find(receipts, &(&1["store"] == "ICA"))
      delete = %{id: "c2", name: "delete_receipt", args: %{"receipt_id" => id}}
      {:ok, {:tool_calls, [delete]}, @usage}
    end)
    |> expect(:chat_with_tools, fn _, _, _, _ -> {:ok, {:message, "Borta."}, @usage} end)

    assert {:ok, _bubbles} = Router.route("ta bort ICA-kvittot", [], ctx)

    assert [%{id: id}] = Costs.recent_receipts(home_scope(), 10)
    assert id == coop.id
    refute id == ica.id
  end
end
