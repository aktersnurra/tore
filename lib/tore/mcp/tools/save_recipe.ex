defmodule Tore.Mcp.Tools.SaveRecipe do
  @moduledoc """
  Saves a recipe pi read from a page or a photo, in the shape `schema/0` describes (which
  `get_recipe` gives and `update_recipe` takes). The run passes `RecipeProposalVerifier` like any
  recipe.
  """
  @behaviour Tore.Mcp.Tool

  alias Tore.Recipes
  alias Tore.Harness.{KitchenRun, Runs}
  alias Tore.Harness.Artifact.RecipeProposal
  alias Tore.Harness.Kinds.RecipeIngestion

  @impl true
  def name, do: "save_recipe"

  @impl true
  def description,
    do: """
    Saves a recipe you read from a page or a photo, in the household's language. Ingredients \
    are `item`, `quantity` and `unit`; `item` is only what you buy (parmesanost, not "parmesanost, \
    riven"), since the shopping list and pantry match on it; how it's cut or served belongs in a \
    step. Steps are single actions in cooking order, grouped by a \
    `phase` in capitals (MISE EN PLACE, SAUCE, …), with `duration_minutes` for a step that waits. \
    `recipe_type` puts it in a collection: meal (a dinner, the only kind that's planned), baking, \
    component (sauces, dressings, sides) or assembly. \
    Give `source_url` for a page, and `image_url` for the page's own picture. A recipe the \
    household already has is refused.\
    """

  @impl true
  def schema,
    do: %{
      "type" => "object",
      "required" => ["title", "ingredients", "steps"],
      "additionalProperties" => false,
      "properties" => %{
        "title" => %{"type" => "string"},
        "recipe_type" => %{
          "type" => "string",
          "enum" => ["meal", "baking", "component", "assembly"]
        },
        "description" => %{"type" => ["string", "null"]},
        "prep_time_minutes" => %{"type" => ["integer", "null"]},
        "cook_time_minutes" => %{"type" => ["integer", "null"]},
        "base_servings" => %{"type" => ["integer", "null"]},
        "source_url" => %{"type" => ["string", "null"]},
        "image_url" => %{"type" => ["string", "null"]},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
        "ingredients" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["item"],
            "additionalProperties" => false,
            "properties" => %{
              "item" => %{"type" => "string"},
              "quantity" => %{"type" => ["number", "null"]},
              "unit" => %{"type" => ["string", "null"]}
            }
          }
        },
        "steps" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["order", "action"],
            "additionalProperties" => false,
            "properties" => %{
              "phase" => %{"type" => "string"},
              "order" => %{"type" => "integer"},
              "action" => %{"type" => "string"},
              "ingredients" => %{"type" => "array", "items" => %{"type" => "string"}},
              "duration_minutes" => %{"type" => ["integer", "null"]}
            }
          }
        }
      }
    }

  @impl true
  def call(scope, %{"title" => title, "ingredients" => [_ | _], "steps" => [_ | _]} = args)
      when is_binary(title) do
    url = args["source_url"]
    source = if is_binary(url) and url != "", do: :web_import, else: :photo
    proposal = args |> Recipes.attrs_from_parsed() |> RecipeProposal.from_attrs(source, url)

    case Runs.submit(scope, RecipeIngestion, proposal, %{proposal: proposal, actor: :mcp}) do
      {:ok, %KitchenRun{status: :applied, id: id, undo: {:steps, steps}}} ->
        [recipe_id] = for {:delete_recipe, recipe_id} <- steps, do: recipe_id
        {:ok, %{done: "Saved #{title}.", run_id: id, recipe_id: recipe_id}}

      {:ok, %KitchenRun{failure_code: code}} ->
        {:error, "Not saved: #{code}."}

      {:error, reason} ->
        {:error, "Not saved: #{inspect(reason)}."}
    end
  end

  def call(_scope, _args),
    do: {:error, "save_recipe needs a title, at least one ingredient and at least one step."}
end
