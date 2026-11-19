defmodule Tore.Harness.Artifact.RecipeEdit do
  @moduledoc """
  A change to a saved recipe, output of `:recipe_edit_run`: `recipe` is the whole revised recipe
  as pi sent it (`update_recipe`, the shape `get_recipe` gives), and `image_path` a newly drawn
  picture (`draw_recipe_picture`). Either may be nil.
  """

  @behaviour Tore.Harness.Artifact

  @derive Jason.Encoder
  @enforce_keys [:recipe_id]
  defstruct [:recipe_id, :recipe, :image_path]

  @type t :: %__MODULE__{
          recipe_id: integer(),
          recipe: map() | nil,
          image_path: String.t() | nil
        }

  @impl true
  def kind, do: "RecipeEdit"

  @impl true
  def to_json(%__MODULE__{} = edit),
    do: %{"recipe_id" => edit.recipe_id, "recipe" => edit.recipe, "image_path" => edit.image_path}

  @impl true
  def from_json(%{"recipe_id" => id} = json),
    do: %__MODULE__{recipe_id: id, recipe: json["recipe"], image_path: json["image_path"]}
end
