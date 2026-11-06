defmodule ToreWeb.RecipeImageControllerTest do
  use ToreWeb.ConnCase, async: false
  alias Tore.Storage.{Buckets, Mock}

  setup do
    Mock.reset()
    user = user_fixture(name: "Gustaf")
    # Insert directly via Repo — Recipes.create/1 spawns an async image-generation
    # Task that would race this test by populating image_path behind our backs.
    {:ok, recipe} =
      %Tore.Recipes.Recipe{title: "Roast chicken", recipe_type: :meal}
      |> Tore.Repo.insert()

    %{user: user, recipe: recipe}
  end

  defp authed(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "serves the image bytes for a recipe with an image", %{
    conn: conn,
    user: user,
    recipe: recipe
  } do
    key = "recipes/#{recipe.id}/abc.jpg"
    {:ok, _} = Mock.put_object(Buckets.recipes(), key, "the image bytes")
    {:ok, _} = set_image_path(recipe, key)

    conn = get(authed(conn, user), ~p"/images/recipes/#{recipe.id}")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg; charset=utf-8"]
    assert conn.resp_body == "the image bytes"
  end

  test "returns 404 when the recipe has no image", %{conn: conn, user: user, recipe: recipe} do
    conn = get(authed(conn, user), ~p"/images/recipes/#{recipe.id}")
    assert conn.status == 404
  end

  test "returns 404 when the stored object is missing", %{
    conn: conn,
    user: user,
    recipe: recipe
  } do
    {:ok, _} = set_image_path(recipe, "recipes/#{recipe.id}/missing.jpg")
    conn = get(authed(conn, user), ~p"/images/recipes/#{recipe.id}")
    assert conn.status == 404
  end

  test "redirects unauthenticated requests to login", %{conn: conn, recipe: recipe} do
    conn = get(conn, ~p"/images/recipes/#{recipe.id}")
    assert redirected_to(conn) == "/login"
  end

  defp set_image_path(recipe, key) do
    recipe
    |> Ecto.Changeset.change(image_path: key)
    |> Tore.Repo.update()
  end
end
