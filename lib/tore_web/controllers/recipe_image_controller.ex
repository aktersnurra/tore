defmodule ToreWeb.RecipeImageController do
  use ToreWeb, :controller

  alias Tore.Recipes
  alias Tore.Storage

  def show(conn, %{"id" => id}) do
    recipe = Recipes.get!(conn.assigns.current_scope, id)

    with key when is_binary(key) <- recipe.image_path,
         {:ok, body} <- Storage.client().get_object(Storage.Buckets.recipes(), key) do
      conn
      |> put_resp_content_type("image/jpeg")
      |> send_resp(200, body)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
