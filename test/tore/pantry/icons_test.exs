defmodule Tore.Pantry.IconsTest do
  use ExUnit.Case, async: true

  alias Tore.Pantry.Icons

  test "every picture Jev can pick, and every category's, is there" do
    for name <- Icons.all() ++ Enum.map(Tore.Recipes.Ingredient.sections(), &Icons.for_category/1) do
      path = Application.app_dir(:tore, "priv/static/images/food/#{Icons.file(name)}")
      assert File.exists?(path), "no picture #{name} at #{path}"
    end
  end

  test "a row shows Jev's pick while there's a picture of it, and its category's otherwise" do
    assert Icons.shown("butter", "dairy") == "butter"
    assert Icons.shown(nil, "dairy") == "milk"
    # A pick from an older set of pictures (an emoji) falls back too.
    assert Icons.shown("🥛", "canned") == "tin"
  end

  # Jev picked rice for "russin" and crispbread after: it doesn't know the Swedish word, so each
  # picture says what it stands for in Swedish too.
  test "each picture says what it stands for in Swedish as well as English" do
    criteria = Icons.criteria()
    assert criteria["grape"] =~ "raisins" and criteria["grape"] =~ "russin"
    assert criteria["carrot"] =~ "morot"

    for {name, description} <- criteria,
        do: assert(description =~ ";", "#{name} has no Swedish words")
  end

  test "only the pictures there are are known" do
    assert Icons.known?("crispbread")
    refute Icons.known?("spaceship")
    refute Icons.known?(nil)
  end
end
