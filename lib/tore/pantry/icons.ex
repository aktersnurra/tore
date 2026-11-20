defmodule Tore.Pantry.Icons do
  @moduledoc """
  The pictures a pantry row can have: food emoji, drawn by Noto Emoji (Google, Apache 2.0, kept
  in `priv/static/images/emoji`, so every device sees the same picture). Jev picks one per
  ingredient (`Tore.Pantry.Lasts`), from what each one stands for; until it has, a row has its
  category's.
  """

  # Each emoji, and what it stands for, as Jev is told.
  @icons [
    {"🥛", "milk, cream, filmjölk, buttermilk"},
    {"🧈", "butter, margarine"},
    {"🧀", "cheese"},
    {"🥚", "eggs"},
    {"🥣", "yoghurt, kvarg, cereal, muesli, porridge oats"},
    {"🍞", "bread, sliced loaf"},
    {"🥖", "baguette, white bread"},
    {"🥐", "croissant, pastry"},
    {"🫓", "flatbread, tortilla, pita, crispbread"},
    {"🥯", "bagel, bun"},
    {"🥞", "pancakes, pancake mix"},
    {"🍝", "pasta, spaghetti, lasagne sheets"},
    {"🍜", "noodles, ramen"},
    {"🍚", "rice"},
    {"🌾", "flour, grains, bulgur, couscous, semolina"},
    {"🫘", "beans, lentils, chickpeas"},
    {"🥜", "peanuts, peanut butter"},
    {"🌰", "nuts, almonds, seeds"},
    {"🥩", "beef, steak, mince, pork, lamb"},
    {"🍗", "chicken, poultry"},
    {"🥓", "bacon"},
    {"🌭", "sausage, frankfurter, chorizo"},
    {"🍖", "ham, cold cuts, meat on the bone"},
    {"🐟", "fish, salmon, cod"},
    {"🦐", "shrimp, prawns"},
    {"🦀", "crab"},
    {"🦞", "lobster, crayfish"},
    {"🦑", "squid"},
    {"🦪", "oysters, mussels, clams"},
    {"🍅", "tomato, passata, crushed tomatoes, tomato purée"},
    {"🥔", "potato"},
    {"🍠", "sweet potato"},
    {"🥕", "carrot, root vegetables"},
    {"🧅", "onion, shallot, leek"},
    {"🧄", "garlic"},
    {"🫚", "ginger"},
    {"🥒", "cucumber, pickles, zucchini"},
    {"🥬", "lettuce, cabbage, spinach, kale, leafy greens"},
    {"🥦", "broccoli, cauliflower"},
    {"🫑", "bell pepper"},
    {"🌶️", "chili, hot pepper, chili flakes"},
    {"🌽", "corn"},
    {"🫛", "peas, edamame"},
    {"🍆", "aubergine, eggplant"},
    {"🍄", "mushrooms"},
    {"🥑", "avocado"},
    {"🫒", "olives, olive oil"},
    {"🌿", "fresh herbs, basil, parsley, dill, coriander"},
    {"🧂", "salt, spices, stock cubes"},
    {"🍯", "honey, syrup, jam"},
    {"🫙", "jar: sauce, pesto, mustard, mayonnaise, condiments"},
    {"🥫", "tin: canned food, coconut milk, soup"},
    {"🫗", "oil, vinegar, soy sauce, other bottled liquids"},
    {"🍎", "apple"},
    {"🍐", "pear"},
    {"🍊", "orange, clementine"},
    {"🍋", "lemon, lime"},
    {"🍌", "banana"},
    {"🍇", "grapes, raisins"},
    {"🍓", "strawberries"},
    {"🫐", "blueberries, berries"},
    {"🍒", "cherries"},
    {"🍑", "peach, nectarine, apricot"},
    {"🥭", "mango"},
    {"🍍", "pineapple"},
    {"🍉", "watermelon"},
    {"🍈", "melon"},
    {"🥝", "kiwi"},
    {"🥥", "coconut"},
    {"🍫", "chocolate, cocoa"},
    {"🍪", "biscuits, cookies"},
    {"🍰", "cake"},
    {"🍦", "ice cream"},
    {"🍬", "sweets, candy"},
    {"🍿", "popcorn, crisps, snacks"},
    {"🥟", "dumplings"},
    {"🍕", "pizza"},
    {"🥗", "salad, ready meals"},
    {"☕", "coffee"},
    {"🍵", "tea"},
    {"🧃", "juice"},
    {"🥤", "soft drink, soda"},
    {"🍺", "beer"},
    {"🍷", "wine"},
    {"🧊", "ice, frozen food"},
    {"🍼", "baby food, formula"}
  ]

  @emoji Enum.map(@icons, &elem(&1, 0))

  @doc "What each emoji stands for, by emoji, as Jev's criteria."
  @spec criteria() :: %{String.t() => String.t()}
  def criteria, do: Map.new(@icons)

  @doc "The emojis there are pictures of."
  @spec all() :: [String.t()]
  def all, do: @emoji

  @doc "Whether there's a picture of `emoji`."
  @spec known?(term()) :: boolean()
  def known?(emoji), do: emoji in @emoji

  @doc "The picture's file, as Noto names it: its code points without the emoji variation selector."
  @spec file(String.t()) :: String.t()
  def file(emoji) do
    points =
      for <<point::utf8 <- emoji>>,
          point != 0xFE0F,
          do: point |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")

    "emoji_u#{Enum.join(points, "_")}.svg"
  end

  @doc "A category's picture, for a row Jev hasn't been asked about."
  @spec for_category(String.t() | nil) :: String.t()
  def for_category("dairy"), do: "🥛"
  def for_category("deli"), do: "🧀"
  def for_category("meat"), do: "🥩"
  def for_category("fish"), do: "🐟"
  def for_category("produce"), do: "🥕"
  def for_category("frozen"), do: "🧊"
  def for_category("dry_goods"), do: "🌾"
  def for_category("bread"), do: "🍞"
  def for_category("beverages"), do: "🧃"
  def for_category("herbs_spices"), do: "🌿"
  def for_category("canned"), do: "🥫"
  def for_category("condiments"), do: "🫙"
  def for_category(_category), do: "🥣"
end
