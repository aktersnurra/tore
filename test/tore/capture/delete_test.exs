defmodule Tore.Capture.DeleteTest do
  use Tore.DataCase, async: false

  import Mox

  alias Tore.{Recipes, Shop, Streams}
  alias Tore.Capture.Dispatch

  setup :verify_on_exit!

  @usage %{prompt_tokens: 1, completion_tokens: 1, cost_usd: Decimal.new(0)}

  setup do
    Gettext.put_locale(ToreWeb.Gettext, "sv")
    user = user_fixture()
    %{ctx: capture_ctx(home_scope().household_id, user.id), user: user}
  end

  test "remove_shopping_item takes the item off this week's list", %{ctx: ctx} do
    stub(Tore.MockLLM, :text, fn _, _, _ -> {:ok, %{"section" => "dairy"}, @usage} end)
    list_id = Streams.shop_list(home_scope(), Tore.Clock.today())
    {:ok, _} = Shop.add_item(home_scope(), list_id, "mjölk", nil, nil, nil)

    bubble = Dispatch.remove_shopping_item("mjölk", ctx)

    assert bubble.text =~ "mjölk"
    assert {:ok, %{items: items}} = Shop.load_list(home_scope(), list_id)
    assert items == %{}
  end

  test "delete_recipe deletes it, and says so when there's none", %{ctx: ctx} do
    {:ok, soup} = Recipes.create(home_scope(), %{title: "Soppa", base_servings: 4})

    assert Dispatch.delete_recipe(soup.id, ctx).text =~ "Soppa"
    assert Recipes.get(home_scope(), soup.id) == nil
    refute Dispatch.delete_recipe(soup.id, ctx).text =~ "Soppa"
  end
end
