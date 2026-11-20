defmodule Tore.Pantry.Icons do
  @moduledoc """
  The pictures a pantry row can have: Iconito's Food icons (MIT), with a few drawn in the same
  style for what a pantry has and the set doesn't (tin, jar, salt, frozen, avocado, chili,
  ginger, crispbread). They're kept in `priv/static/images/food`, so every device sees the same
  picture. Jev picks one per ingredient (`Tore.Pantry.Lasts`), from what each stands for; until
  it has, a row has its category's.
  """

  # Each picture, by name, and what it stands for, as Jev is told.
  @icons [
    {"milk", "milk, filmjölk, buttermilk"},
    {"cream", "cream, crème fraîche, sour cream"},
    {"butter", "butter, margarine"},
    {"cheese", "cheese"},
    {"yogurt", "yoghurt, kvarg, cottage cheese"},
    {"egg", "eggs"},
    {"tofu", "tofu, halloumi, plant protein"},
    {"bread", "bread, a loaf, buns"},
    {"baguette", "baguette, white bread"},
    {"croissant", "croissant, pastries"},
    {"tortilla", "tortillas, wraps, pita, flatbread"},
    {"crispbread", "crispbread (knäckebröd), rice cakes"},
    {"pancake", "pancakes, pancake mix"},
    {"pasta", "pasta, spaghetti, lasagne sheets"},
    {"noodles", "noodles"},
    {"rice", "rice"},
    {"quinoa", "quinoa, bulgur, couscous"},
    {"flour", "flour, baking powder, yeast"},
    {"sugar", "sugar"},
    {"oats", "oats, muesli, cereal"},
    {"bean", "beans"},
    {"chickpea", "chickpeas"},
    {"lentil", "lentils"},
    {"almond", "almonds, nuts, seeds"},
    {"walnut", "walnuts"},
    {"peanut", "peanuts, peanut butter"},
    {"beef", "beef, steak, mince"},
    {"pork", "pork"},
    {"lamb", "lamb"},
    {"ham", "ham, cold cuts"},
    {"bacon", "bacon"},
    {"sausage", "sausage, chorizo, hot dogs"},
    {"chicken", "chicken"},
    {"turkey", "turkey"},
    {"meatball", "meatballs"},
    {"fish", "fish, cod, white fish"},
    {"salmon", "salmon"},
    {"tuna", "tuna"},
    {"shrimp", "shrimp, prawns"},
    {"squid", "squid, mussels, seafood"},
    {"tomato", "tomatoes"},
    {"potato", "potatoes, sweet potatoes"},
    {"carrot", "carrots, root vegetables"},
    {"onion", "onion, shallot, leek"},
    {"garlic", "garlic"},
    {"ginger", "ginger"},
    {"cucumber", "cucumber"},
    {"zucchini", "zucchini, aubergine"},
    {"lettuce", "lettuce, cabbage, salad leaves"},
    {"spinach", "spinach"},
    {"kale", "kale"},
    {"broccoli", "broccoli, cauliflower"},
    {"bell_pepper", "bell pepper"},
    {"chili", "chili, hot pepper"},
    {"corn", "corn"},
    {"mushroom", "mushrooms"},
    {"avocado", "avocado"},
    {"olive", "olives"},
    {"basil", "basil"},
    {"parsley", "parsley, dill"},
    {"cilantro", "coriander"},
    {"mint", "mint"},
    {"rosemary", "rosemary"},
    {"thyme", "thyme"},
    {"oregano", "oregano, dried herbs"},
    {"salt", "salt, pepper, spices, stock cubes"},
    {"olive_oil", "olive oil, cooking oil"},
    {"vinegar", "vinegar, soy sauce, bottled sauces"},
    {"mayonnaise", "mayonnaise, ketchup, sauces in tubes"},
    {"jar", "a jar: pesto, mustard, pickles, jarred sauces"},
    {"tin", "a tin: crushed tomatoes, coconut milk, tinned food"},
    {"honey", "honey, jam, marmalade"},
    {"maple_syrup", "syrup"},
    {"apple", "apples, pears"},
    {"banana", "bananas"},
    {"orange", "oranges, clementines"},
    {"lemon", "lemons"},
    {"lime", "limes"},
    {"grape", "grapes, raisins"},
    {"strawberry", "strawberries"},
    {"blueberry", "blueberries, berries"},
    {"watermelon", "melon"},
    {"chocolate", "chocolate, cocoa"},
    {"cookie", "biscuits, cookies"},
    {"candy", "sweets"},
    {"cake", "cake"},
    {"ice_cream", "ice cream"},
    {"frozen", "frozen food, ice"},
    {"pizza", "pizza"},
    {"dumpling", "dumplings"},
    {"fries", "chips, fries, crisps"},
    {"soup", "soup"},
    {"coffee", "coffee"},
    {"tea", "tea"},
    {"juice", "juice"},
    {"soda", "soft drinks"},
    {"water", "bottled or sparkling water"},
    {"beer", "beer"},
    {"wine", "wine"}
  ]

  @names Enum.map(@icons, &elem(&1, 0))

  @doc "What each picture stands for, by name, as Jev's criteria."
  @spec criteria() :: %{String.t() => String.t()}
  def criteria, do: Map.new(@icons)

  @doc "The pictures there are, by name."
  @spec all() :: [String.t()]
  def all, do: @names

  @doc "Whether there's a picture called `name`."
  @spec known?(term()) :: boolean()
  def known?(name), do: name in @names

  @doc "The picture's file in `priv/static/images/food`."
  @spec file(String.t()) :: String.t()
  def file(name), do: name <> ".svg"

  @doc """
  The picture a row shows: Jev's pick while there's a picture of it (a pick can outlive the set
  it was made from), otherwise its category's.
  """
  @spec shown(String.t() | nil, String.t() | nil) :: String.t()
  def shown(icon, category), do: if(known?(icon), do: icon, else: for_category(category))

  @doc "A category's picture, for a row Jev hasn't been asked about."
  @spec for_category(String.t() | nil) :: String.t()
  def for_category("dairy"), do: "milk"
  def for_category("deli"), do: "cheese"
  def for_category("meat"), do: "beef"
  def for_category("fish"), do: "fish"
  def for_category("produce"), do: "carrot"
  def for_category("frozen"), do: "frozen"
  def for_category("dry_goods"), do: "flour"
  def for_category("bread"), do: "bread"
  def for_category("beverages"), do: "juice"
  def for_category("herbs_spices"), do: "salt"
  def for_category("canned"), do: "tin"
  def for_category(_category), do: "jar"
end
