defmodule ToreWeb.Look do
  @moduledoc """
  How a recipe looks when there's no photograph to show, and how its collection is marked: an
  icon for the dish, on its collection's tint (ui.md §4.3).

  The icon is read from the dish's name, in Swedish or English, and otherwise the collection's
  own: no model is asked. A picture is drawn for every recipe (`Tore.Recipes.start_image/3`), so
  the tinted icon is what shows while it's being drawn, or if drawing failed.
  """

  use Phoenix.Component
  use Gettext, backend: ToreWeb.Gettext
  alias Phoenix.LiveView.JS

  @collections [:meal, :baking, :component, :assembly]

  # Checked in order; the first word found in the name decides. Words are matched at the start
  # of a word or anywhere in a compound ("laxpasta" is fish), so short words that hide inside
  # others ("ost" in "rostbiff") are matched at a word's start only, with a leading "^".
  @dishes [
    {"ph-shrimp-duotone", ~w(räk scampi shrimp prawn)},
    {"ph-fish-duotone", ~w(lax torsk fisk sej tonfisk sill makrill salmon fish ^cod tuna)},
    {"ph-pizza-duotone", ~w(pizza)},
    {"ph-hamburger-duotone", ~w(hamburgare burgare burger)},
    {"ph-egg-duotone", ~w(omelett äggröra ^ägg ^egg frittata)},
    {"ph-leaf-duotone", ~w(sallad salad)},
    {"ph-bowl-steam-duotone", ~w(soppa soup ramen nudel noodle pho)},
    {"ph-cooking-pot-duotone", ~w(gryta stew curry chili gulasch ragu ^dal)},
    {"ph-knife-duotone", ~w(oxfilé biff entrecote fläskfilé kotlett steak schnitzel)},
    {"ph-bread-duotone", ~w(bröd limpa surdeg fralla baguette focaccia bread)},
    {"ph-cake-duotone", ~w(tårta sockerkaka kladdkaka cake muffin)},
    {"ph-cookie-duotone", ~w(bulle bullar kaka kakor cookie biscuit)},
    {"ph-ice-cream-duotone", ~w(glass ice-cream)},
    {"ph-jar-label-duotone", ~w(sås sauce dressing aioli pesto majonnäs mayo chutney sylt)},
    {"ph-cheese-duotone", ~w(^ost cheese)},
    {"ph-avocado-duotone", ~w(avokado guacamole avocado)},
    {"ph-pepper-duotone", ~w(paprika)},
    {"ph-carrot-duotone", ~w(morot morötter carrot)},
    {"ph-coffee-duotone", ~w(kaffe coffee)},
    {"ph-bowl-food-duotone", ~w(pasta risotto bowl wok)}
  ]

  @doc """
  The icon class for a dish: from its name, or its collection's.

      iex> ToreWeb.Look.icon(%{title: "Laxpasta", recipe_type: :meal})
      "ph-fish-duotone"
      iex> ToreWeb.Look.icon(%{title: "Rostad potatis", recipe_type: :meal})
      "ph-cooking-pot-duotone"
      iex> ToreWeb.Look.icon(%{title: "Kanelbullar", recipe_type: :baking})
      "ph-cookie-duotone"
  """
  @spec icon(%{required(:title) => String.t() | nil, optional(:recipe_type) => atom()}) ::
          String.t()
  def icon(%{title: title} = dish) do
    name = String.downcase(title || "")
    words = String.split(name, ~r/[^\p{L}-]+/u, trim: true)

    Enum.find_value(@dishes, collection_icon(Map.get(dish, :recipe_type, :meal)), fn {icon, keys} ->
      if Enum.any?(keys, &mentions?(name, words, &1)), do: icon
    end)
  end

  defp mentions?(_name, words, "^" <> key), do: Enum.any?(words, &String.starts_with?(&1, key))
  defp mentions?(name, _words, key), do: String.contains?(name, key)

  @doc "A collection's icon class."
  @spec collection_icon(atom() | String.t()) :: String.t()
  def collection_icon(type) when is_binary(type),
    do: collection_icon(String.to_existing_atom(type))

  def collection_icon(:meal), do: "ph-cooking-pot-duotone"
  def collection_icon(:baking), do: "ph-bread-duotone"
  def collection_icon(:component), do: "ph-jar-label-duotone"
  def collection_icon(:assembly), do: "ph-bowl-food-duotone"

  @doc "A collection's tag colour: the `.tag-…` and `.tint-…` suffix."
  @spec tint(atom() | String.t()) :: String.t()
  def tint(type) when is_binary(type), do: tint(String.to_existing_atom(type))
  def tint(:meal), do: "orange"
  def tint(:baking), do: "yellow"
  def tint(:component), do: "green"
  def tint(:assembly), do: "blue"

  @doc "The collections, in the order they're shown."
  def collections, do: @collections

  @doc """
  Where a dish's photograph would be: its icon on its collection's tint, filling the box it's
  put in. Shown while the picture is drawn, so no dish is ever an empty grey block.
  """
  attr :dish, :map, required: true, doc: "anything with :title, and :recipe_type if known"
  attr :class, :any, default: "absolute inset-0"
  attr :icon_class, :any, default: "size-10"

  def blank_cover(assigns) do
    assigns = assign(assigns, :type, Map.get(assigns.dish, :recipe_type) || :meal)

    ~H"""
    <span
      class={["flex items-center justify-center", "tint-#{tint(@type)}", @class]}
      data-role="blank-cover"
      aria-hidden="true"
    >
      <span class={[icon(@dish), @icon_class]}></span>
    </span>
    """
  end

  attr :id, :string, required: true, doc: "the id of the list it folds"
  attr :label, :string, required: true
  attr :tint, :string, required: true
  attr :count, :integer, required: true
  attr :open, :boolean, default: true

  @doc "A group's head: a caret that folds the list under it, the group's tag, and the count."
  def group_head(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={
        JS.toggle(to: "##{@id}")
        |> JS.toggle_class("rotate-90", to: "##{@id}-caret")
        |> JS.toggle_attribute({"aria-expanded", "true", "false"})
      }
      aria-expanded={to_string(@open)}
      aria-controls={@id}
      data-role="group-head"
      class="press -ml-1 flex h-8 items-center gap-1.5"
    >
      <span
        id={"#{@id}-caret"}
        class={[
          "ph-caret-right size-4 text-[color:var(--muted)] transition-transform duration-[var(--dur-fast)]",
          @open && "rotate-90"
        ]}
      >
      </span>
      <span class={["tag", "tag-#{@tint}"]}>{@label}</span>
      <span class="num text-[13px] text-[color:var(--muted)]">{@count}</span>
    </button>
    """
  end

  @doc "A page's icon: a duotone icon on a soft tinted square, above the page's title."
  attr :icon, :string, required: true
  attr :tint, :string, default: "grey"
  attr :class, :any, default: "size-14 rounded-[var(--r-xl)]"

  def page_icon(assigns) do
    ~H"""
    <span
      class={["inline-flex items-center justify-center", "tint-#{@tint}", @class]}
      aria-hidden="true"
    >
      <span class={[@icon, "size-[58%]"]}></span>
    </span>
    """
  end

  @doc "A shop section's name, as on Shop. A string section is one of `Ingredient.sections/0`."
  @spec section_label(atom() | String.t()) :: String.t()
  def section_label(section) when is_binary(section),
    do: section_label(String.to_existing_atom(section))

  def section_label(:produce), do: gettext("Produce")
  def section_label(:meat), do: gettext("Meat")
  def section_label(:fish), do: gettext("Fish & Seafood")
  def section_label(:dairy), do: gettext("Dairy & Eggs")
  def section_label(:deli), do: gettext("Deli")
  def section_label(:frozen), do: gettext("Frozen")
  def section_label(:bread), do: gettext("Bread")
  def section_label(:canned), do: gettext("Canned Goods")
  def section_label(:beverages), do: gettext("Beverages")
  def section_label(:herbs_spices), do: gettext("Herbs & Spices")
  def section_label(:condiments), do: gettext("Condiments & Oils")
  def section_label(:household), do: gettext("Household")
  def section_label(:dry_goods), do: gettext("Dry Goods")
  def section_label(:other), do: gettext("Other")

  @doc "A shop section's tint: the tint of what's in it; most of the shop is quiet grey."
  @spec section_tint(atom() | String.t()) :: String.t()
  def section_tint(section) when is_binary(section),
    do: section_tint(String.to_existing_atom(section))

  def section_tint(section) when section in [:produce, :herbs_spices], do: "green"
  def section_tint(section) when section in [:dairy, :frozen, :fish], do: "blue"

  def section_tint(section) when section in [:dry_goods, :bread, :canned, :condiments],
    do: "yellow"

  def section_tint(section) when section in [:meat, :deli], do: "orange"
  def section_tint(_section), do: "grey"
end
