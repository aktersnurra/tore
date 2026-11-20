defmodule Tore.Pantry.IconsTest do
  use ExUnit.Case, async: true

  alias Tore.Pantry.Icons

  test "every emoji Jev can pick, and every category's, has its picture" do
    for emoji <- Icons.all() ++ Enum.map(Tore.Recipes.Ingredient.sections(), &Icons.for_category/1) do
      path = Application.app_dir(:tore, "priv/static/images/emoji/#{Icons.file(emoji)}")
      assert File.exists?(path), "no picture of #{emoji} at #{path}"
    end
  end

  test "a picture's file is named as Noto names it, without the variation selector" do
    assert Icons.file("🥛") == "emoji_u1f95b.svg"
    assert Icons.file("🌶️") == "emoji_u1f336.svg"
    assert Icons.file("☕") == "emoji_u2615.svg"
  end

  test "only the emoji there are pictures of are known" do
    assert Icons.known?("🧈")
    refute Icons.known?("🛸")
    refute Icons.known?(nil)
  end
end
