defmodule Tore.Pantry.Icons do
  @moduledoc """
  The pictures a pantry row can have: Iconito's Food icons (MIT), with a few drawn in the same
  style for what a pantry has and the set doesn't (tin, jar, salt, frozen, avocado, chili,
  ginger, crispbread). They're kept in `priv/static/images/food`, so every device sees the same
  picture. Jev picks one per ingredient (`Tore.Pantry.Lasts`), from what each stands for; until
  it has, a row has its category's.
  """

  # Each picture, by name, and what it stands for, as Jev is told: in English, then in Swedish,
  # since Jev guesses at a Swedish name it doesn't know ("russin" got rice) but matches its word.
  @icons [
    {"milk", "milk, filmjölk, buttermilk; mjölk, filmjölk, kärnmjölk"},
    {"cream", "cream, crème fraîche, sour cream; grädde, crème fraîche, gräddfil"},
    {"butter", "butter, margarine; smör, margarin"},
    {"cheese", "cheese; ost, cheddar, parmesan, gräddost"},
    {"yogurt", "yoghurt, kvarg, cottage cheese; yoghurt, kvarg, keso"},
    {"egg", "eggs; ägg"},
    {"tofu", "tofu, halloumi, plant protein; tofu, halloumi, vegoprotein"},
    {"bread", "bread, a loaf, buns; bröd, limpa, bullar"},
    {"baguette", "baguette, white bread; baguette, vitt bröd"},
    {"croissant", "croissant, pastries; croissant, bakverk, wienerbröd"},
    {"tortilla", "tortillas, wraps, pita, flatbread; tortilla, wraps, pitabröd, tunnbröd"},
    {"crispbread", "crispbread (knäckebröd), rice cakes; knäckebröd, riskakor"},
    {"pancake", "pancakes, pancake mix; pannkakor, pannkaksmix"},
    {"pasta", "pasta, spaghetti, lasagne sheets; pasta, spaghetti, lasagneplattor"},
    {"noodles", "noodles; nudlar"},
    {"rice", "rice; ris"},
    {"quinoa", "quinoa, bulgur, couscous; quinoa, bulgur, couscous"},
    {"flour", "flour, baking powder, yeast; mjöl, bakpulver, jäst"},
    {"sugar", "sugar; socker, strösocker"},
    {"oats", "oats, muesli, cereal; havregryn, müsli, flingor"},
    {"bean", "beans; bönor"},
    {"chickpea", "chickpeas; kikärtor"},
    {"lentil", "lentils; linser"},
    {"almond", "almonds, nuts, seeds; mandel, nötter, frön"},
    {"walnut", "walnuts; valnötter"},
    {"peanut", "peanuts, peanut butter; jordnötter, jordnötssmör"},
    {"beef", "beef, steak, mince; nötkött, biff, köttfärs, nötfärs"},
    {"pork", "pork; fläskkött, fläsk"},
    {"lamb", "lamb; lamm"},
    {"ham", "ham, cold cuts; skinka, pålägg"},
    {"bacon", "bacon; bacon, pancetta"},
    {"sausage", "sausage, chorizo, hot dogs; korv, chorizo, varmkorv"},
    {"chicken", "chicken; kyckling"},
    {"turkey", "turkey; kalkon"},
    {"meatball", "meatballs; köttbullar"},
    {"fish", "fish, cod, white fish; fisk, torsk, vitfisk"},
    {"salmon", "salmon; lax"},
    {"tuna", "tuna; tonfisk"},
    {"shrimp", "shrimp, prawns; räkor"},
    {"squid", "squid, mussels, seafood; bläckfisk, musslor, skaldjur"},
    {"tomato", "tomatoes; tomater"},
    {"potato", "potatoes, sweet potatoes; potatis, sötpotatis"},
    {"carrot", "carrots, root vegetables; morot, morötter, rotfrukter"},
    {"onion", "onion, shallot, leek; lök, gul lök, schalottenlök, purjolök"},
    {"garlic", "garlic; vitlök"},
    {"ginger", "ginger; ingefära"},
    {"cucumber", "cucumber; gurka"},
    {"zucchini", "zucchini, aubergine; zucchini, aubergine"},
    {"lettuce", "lettuce, cabbage, salad leaves; sallad, kål, salladsblad"},
    {"spinach", "spinach; spenat"},
    {"kale", "kale; grönkål"},
    {"broccoli", "broccoli, cauliflower; broccoli, blomkål"},
    {"bell_pepper", "bell pepper; paprika"},
    {"chili", "chili, hot pepper; chili, chilifrukt, chiliflingor"},
    {"corn", "corn; majs"},
    {"mushroom", "mushrooms; svamp, champinjoner"},
    {"avocado", "avocado; avokado"},
    {"olive", "olives; oliver"},
    {"basil", "basil; basilika"},
    {"parsley", "parsley, dill; persilja, dill"},
    {"cilantro", "coriander; koriander"},
    {"mint", "mint; mynta"},
    {"rosemary", "rosemary; rosmarin"},
    {"thyme", "thyme; timjan"},
    {"oregano", "oregano, dried herbs; oregano, torkade örter"},
    {"salt", "salt, pepper, spices, stock cubes; salt, peppar, kryddor, buljongtärningar"},
    {"olive_oil", "olive oil, cooking oil; olivolja, matolja, rapsolja"},
    {"vinegar", "vinegar, soy sauce, bottled sauces; vinäger, ättika, soja, flasksåser"},
    {"mayonnaise", "mayonnaise, ketchup, sauces in tubes; majonnäs, ketchup, tubsåser"},
    {"jar",
     "a jar: pesto, mustard, pickles, jarred sauces; burk: pesto, senap, inlagt, burksåser"},
    {"tin",
     "a tin: crushed tomatoes, coconut milk, tinned food; konservburk: krossade tomater, kokosmjölk, konserver"},
    {"honey", "honey, jam, marmalade; honung, sylt, marmelad"},
    {"maple_syrup", "syrup; sirap"},
    {"apple", "apples, pears; äpplen, päron"},
    {"banana", "bananas; bananer"},
    {"orange", "oranges, clementines; apelsiner, clementiner"},
    {"lemon", "lemons; citroner"},
    {"lime", "limes; lime"},
    {"grape", "grapes, raisins; vindruvor, russin"},
    {"strawberry", "strawberries; jordgubbar"},
    {"blueberry", "blueberries, berries; blåbär, bär"},
    {"watermelon", "melon; melon, vattenmelon"},
    {"chocolate", "chocolate, cocoa; choklad, kakao"},
    {"cookie", "biscuits, cookies; kex, kakor"},
    {"candy", "sweets; godis"},
    {"cake", "cake; tårta, kaka"},
    {"ice_cream", "ice cream; glass"},
    {"frozen", "frozen food, ice; frysvaror, is"},
    {"pizza", "pizza; pizza"},
    {"dumpling", "dumplings; dumplings"},
    {"fries", "chips, fries, crisps; chips, pommes frites"},
    {"soup", "soup; soppa"},
    {"coffee", "coffee; kaffe"},
    {"tea", "tea; te"},
    {"juice", "juice; juice"},
    {"soda", "soft drinks; läsk"},
    {"water", "bottled or sparkling water; vatten, kolsyrat vatten"},
    {"beer", "beer; öl"},
    {"wine", "wine; vin, rött vin, vitt vin"}
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
