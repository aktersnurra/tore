defmodule ToreWeb.RecipeImageControllerTest do
  use ToreWeb.ConnCase, async: false
  alias Tore.Storage.{Buckets, Mock}

  setup do
    Mock.reset()
    user = user_fixture(name: "Gustaf")
    # Insert directly via Repo — Recipes.create/1 spawns an async image-generation
    # Task that would race this test by populating image_path behind our backs.
    {:ok, recipe} =
      %Tore.Recipes.Recipe{
        household_id: home_scope().household_id,
        title: "Roast chicken",
        recipe_type: :meal
      }
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
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
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

  test "another household's recipe image is a 404", %{conn: conn, user: user} do
    {:ok, theirs} =
      %Tore.Recipes.Recipe{
        household_id: household_fixture().id,
        title: "Kåldolmar",
        recipe_type: :meal,
        image_path: "households/0/recipes/0/theirs.jpg"
      }
      |> Tore.Repo.insert()

    {:ok, _} = Mock.put_object(Buckets.recipes(), theirs.image_path, "their bytes")

    assert_error_sent 404, fn -> get(authed(conn, user), ~p"/images/recipes/#{theirs.id}") end
  end

  test "redirects unauthenticated requests to login", %{conn: conn, recipe: recipe} do
    conn = get(conn, ~p"/images/recipes/#{recipe.id}")
    assert redirected_to(conn) == "/login"
  end

  describe "caching" do
    setup %{recipe: recipe} do
      key = "recipes/#{recipe.id}/abc.jpg"
      {:ok, _} = Mock.put_object(Buckets.recipes(), key, "the image bytes")
      {:ok, recipe} = set_image_path(recipe, key)
      %{recipe: recipe, version: ToreWeb.RecipeImage.version(key)}
    end

    test "a versioned URL is kept for a year", %{conn: conn, user: user, recipe: recipe} do
      conn = get(authed(conn, user), ToreWeb.RecipeImage.path(recipe))

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    end

    test "an unversioned or stale URL is revalidated", %{conn: conn, user: user, recipe: recipe} do
      for path <- [~p"/images/recipes/#{recipe.id}", ~p"/images/recipes/#{recipe.id}?v=old"] do
        conn = get(authed(conn, user), path)
        assert conn.status == 200
        assert get_resp_header(conn, "cache-control") == ["private, no-cache"]
      end
    end

    test "a matching ETag is a 304 without reading storage", %{
      conn: conn,
      user: user,
      recipe: recipe,
      version: version
    } do
      Mock.reset()

      conn =
        conn
        |> authed(user)
        |> put_req_header("if-none-match", ~s(W/"#{version}"))
        |> get(~p"/images/recipes/#{recipe.id}")

      assert conn.status == 304
      assert conn.resp_body == ""
      assert get_resp_header(conn, "etag") == [~s("#{version}")]
    end

    test "a new picture is a new URL", %{recipe: recipe} do
      before = ToreWeb.RecipeImage.path(recipe)
      assert before =~ "/images/recipes/#{recipe.id}?v="

      refute ToreWeb.RecipeImage.path(%{recipe | image_path: "recipes/#{recipe.id}/new.jpg"}) ==
               before

      assert ToreWeb.RecipeImage.path(%{recipe | image_path: nil}) == nil
    end

    test "a width is served small, as WebP, with its own ETag", %{
      conn: conn,
      user: user,
      recipe: recipe,
      version: version
    } do
      conn = get(authed(conn, user), ToreWeb.RecipeImage.path(recipe, 256))

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["image/webp"]
      assert conn.resp_body =~ "256:the image bytes"
      assert get_resp_header(conn, "etag") == [~s("#{version}-256")]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    end

    test "a width that can't be made is the original, kept only an hour", %{
      conn: conn,
      user: user,
      recipe: recipe
    } do
      {:ok, _} = Mock.put_object(Buckets.recipes(), recipe.image_path, "not an image")
      conn = get(authed(conn, user), ToreWeb.RecipeImage.path(recipe, 720))

      assert conn.status == 200
      assert conn.resp_body == "not an image"
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
      assert get_resp_header(conn, "etag") == []
    end

    test "a width Tore doesn't make is the original", %{conn: conn, user: user, recipe: recipe} do
      conn = get(authed(conn, user), ~p"/images/recipes/#{recipe.id}?w=999")
      assert conn.resp_body == "the image bytes"
    end

    test "says PNG when the bytes are PNG", %{conn: conn, user: user, recipe: recipe} do
      {:ok, _} = Mock.put_object(Buckets.recipes(), recipe.image_path, <<0x89, "PNG", 13, 10, 26, 10>>)
      conn = get(authed(conn, user), ~p"/images/recipes/#{recipe.id}")
      assert get_resp_header(conn, "content-type") == ["image/png"]
    end
  end

  defp set_image_path(recipe, key) do
    recipe
    |> Ecto.Changeset.change(image_path: key)
    |> Tore.Repo.update()
  end
end
