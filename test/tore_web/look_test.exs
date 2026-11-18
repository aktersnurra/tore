defmodule ToreWeb.LookTest do
  use ExUnit.Case, async: true

  alias ToreWeb.Look

  doctest Look

  describe "icon/1" do
    test "reads the dish from its name, compounds included" do
      assert Look.icon(%{title: "Kycklinggryta", recipe_type: :meal}) == "ph-cooking-pot-duotone"
      assert Look.icon(%{title: "Räksmörgås", recipe_type: :assembly}) == "ph-shrimp-duotone"
      assert Look.icon(%{title: "Surdegsbröd", recipe_type: :baking}) == "ph-bread-duotone"

      assert Look.icon(%{title: "Bearnaisesås", recipe_type: :component}) ==
               "ph-jar-label-duotone"

      assert Look.icon(%{title: "Tomato soup"}) == "ph-bowl-steam-duotone"
    end

    test "matches a short word only at the start of a word" do
      assert Look.icon(%{title: "Ostkaka", recipe_type: :baking}) == "ph-cookie-duotone"
      assert Look.icon(%{title: "Pasta med ost", recipe_type: :meal}) == "ph-cheese-duotone"
      assert Look.icon(%{title: "Rostad blomkål", recipe_type: :meal}) == "ph-cooking-pot-duotone"
    end

    test "falls back to the collection's icon" do
      assert Look.icon(%{title: "Mormors specialare", recipe_type: :baking}) == "ph-bread-duotone"
      assert Look.icon(%{title: "Något", recipe_type: :component}) == "ph-jar-label-duotone"
      assert Look.icon(%{title: nil}) == "ph-cooking-pot-duotone"
    end
  end
end
