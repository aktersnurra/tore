defmodule Tore.Harness.Artifact.RecipeProposal do
  @moduledoc """
  A recipe that does not exist in the catalog yet, awaiting user confirmation
  on a `:needs_user` card. Three sources:

    * `:web_import` — parsed from a page the user chose out of web search
      results or pasted into Capture. `source_url` carries the page, and
      `image_url` the page's own picture if it has one.
    * `:photo` — read from photos of a recipe sent to Capture.
    * `:generation` — a variant the planner generated from an existing recipe.
      `source_recipe_id` and `instruction` carry the provenance ("recipe 7,
      made simpler").

  Nothing here is persisted until someone confirms the run, which turns it into
  a real `Tore.Recipes.Recipe`.
  """

  @behaviour Tore.Harness.Artifact

  @derive Jason.Encoder
  @enforce_keys [:title, :ingredients, :source]
  defstruct [
    :title,
    :recipe_type,
    :description,
    :instructions,
    :base_servings,
    :prep_time_minutes,
    :cook_time_minutes,
    :source,
    :source_url,
    :source_recipe_id,
    :instruction,
    :image_url,
    :steps,
    ingredients: [],
    tags: []
  ]

  @type ingredient :: %{
          name: String.t(),
          quantity: String.t() | nil,
          unit: String.t() | nil
        }

  @type source :: :web_import | :generation | :photo

  @type t :: %__MODULE__{
          title: String.t(),
          recipe_type: :meal | :baking | :component | :assembly | nil,
          description: String.t() | nil,
          instructions: String.t() | nil,
          base_servings: pos_integer() | nil,
          prep_time_minutes: non_neg_integer() | nil,
          cook_time_minutes: non_neg_integer() | nil,
          ingredients: [ingredient()],
          tags: [String.t()],
          source: source(),
          source_url: String.t() | nil,
          source_recipe_id: integer() | nil,
          instruction: String.t() | nil,
          image_url: String.t() | nil,
          steps: String.t() | nil
        }

  @doc """
  A proposal from recipe attrs as `Tore.Recipes` parses them from a page or photos. A recipe that
  doesn't say how many it serves is taken to serve 4, as the review can't edit it. A photo's
  picture is never fetched: any address in it is only what the model read or made up.
  """
  @spec from_attrs(map(), :web_import | :photo, String.t() | nil) :: t()
  def from_attrs(attrs, source, source_url) do
    %__MODULE__{
      title: attrs[:title],
      recipe_type: attrs[:recipe_type],
      description: attrs[:description],
      instructions: attrs[:instructions],
      base_servings: attrs[:base_servings] || 4,
      prep_time_minutes: attrs[:prep_time_minutes],
      cook_time_minutes: attrs[:cook_time_minutes],
      ingredients: Enum.map(attrs[:ingredients] || [], &attrs_ingredient/1),
      tags: attrs[:tags] || [],
      source: source,
      source_url: source_url,
      image_url: if(source == :photo, do: nil, else: attrs[:image_url]),
      steps: attrs[:steps]
    }
  end

  defp attrs_ingredient(ing) do
    %{
      name: ing[:name] || ing["name"],
      quantity: quantity_to_string(ing[:quantity] || ing["quantity"]),
      unit: ing[:unit] || ing["unit"]
    }
  end

  @impl true
  def kind, do: "RecipeProposal"

  @impl true
  def to_json(%__MODULE__{} = proposal) do
    %{
      "title" => proposal.title,
      "recipe_type" => proposal.recipe_type && Atom.to_string(proposal.recipe_type),
      "description" => proposal.description,
      "instructions" => proposal.instructions,
      "base_servings" => proposal.base_servings,
      "prep_time_minutes" => proposal.prep_time_minutes,
      "cook_time_minutes" => proposal.cook_time_minutes,
      "ingredients" => Enum.map(proposal.ingredients, &ingredient_to_json/1),
      "tags" => proposal.tags,
      "source" => Atom.to_string(proposal.source),
      "source_url" => proposal.source_url,
      "source_recipe_id" => proposal.source_recipe_id,
      "instruction" => proposal.instruction,
      "image_url" => proposal.image_url,
      "steps" => proposal.steps
    }
  end

  @impl true
  def from_json(%{"title" => title} = json) do
    %__MODULE__{
      title: title,
      recipe_type: recipe_type_from_json(json["recipe_type"]),
      description: json["description"],
      instructions: json["instructions"],
      base_servings: json["base_servings"],
      prep_time_minutes: json["prep_time_minutes"],
      cook_time_minutes: json["cook_time_minutes"],
      ingredients: Enum.map(json["ingredients"] || [], &ingredient_from_json/1),
      tags: json["tags"] || [],
      source: source_from_json(json["source"]),
      source_url: json["source_url"],
      source_recipe_id: json["source_recipe_id"],
      instruction: json["instruction"],
      image_url: json["image_url"],
      steps: json["steps"]
    }
  end

  defp recipe_type_from_json(type) when type in ~w(meal baking component assembly),
    do: String.to_existing_atom(type)

  defp recipe_type_from_json(_), do: nil

  defp ingredient_to_json(ing) do
    %{
      "name" => ing[:name],
      "quantity" => quantity_to_string(ing[:quantity]),
      "unit" => ing[:unit]
    }
  end

  defp ingredient_from_json(json) do
    %{name: json["name"], quantity: json["quantity"], unit: json["unit"]}
  end

  defp quantity_to_string(nil), do: nil
  defp quantity_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp quantity_to_string(n) when is_number(n), do: to_string(n)
  defp quantity_to_string(s) when is_binary(s), do: s

  defp source_from_json("web_import"), do: :web_import
  defp source_from_json("generation"), do: :generation
  defp source_from_json("photo"), do: :photo
end
