defmodule Tore.Recipes.PicturesTest do
  use Tore.DataCase, async: false

  alias Tore.Recipes.Pictures
  alias Tore.Storage.{Buckets, Mock}

  @key "households/1/recipes/1/abc.jpg"

  setup do
    Mock.reset()
    {:ok, _} = Mock.put_object(Buckets.recipes(), @key, "original")
    :ok
  end

  test "a width is made once and then read back" do
    assert {:ok, small, :resized} = Pictures.get(@key, 256)
    assert small =~ "256:original"
    assert {:ok, ^small} = Mock.get_object(Buckets.recipes(), @key <> ".w256.webp")

    {:ok, _} = Mock.put_object(Buckets.recipes(), @key, "changed under it")
    assert {:ok, ^small, :resized} = Pictures.get(@key, 256)
  end

  test "no width is the original" do
    assert {:ok, "original", :original} = Pictures.get(@key, nil)
  end

  test "the original stands in when it can't be resized" do
    {:ok, _} = Mock.put_object(Buckets.recipes(), @key, "not an image")
    assert {:ok, "not an image", :original} = Pictures.get(@key, 720)
    assert {:error, :not_found} = Mock.get_object(Buckets.recipes(), @key <> ".w720.webp")
  end

  test "a missing picture is an error" do
    assert {:error, :not_found} = Pictures.get("nope.jpg", 720)
  end

  test "warm_all makes every household's pictures, skipping widths already kept" do
    other = household_fixture()

    for {household_id, key} <- [{home_scope().household_id, @key}, {other.id, "b.jpg"}] do
      {:ok, _} = Mock.put_object(Buckets.recipes(), key, "original")

      Tore.Repo.insert!(%Tore.Recipes.Recipe{
        household_id: household_id,
        title: key,
        recipe_type: :meal,
        image_path: key
      })
    end

    {:ok, _} = Mock.put_object(Buckets.recipes(), @key <> ".w256.webp", "kept")
    :ok = Pictures.warm_all()

    assert {:ok, "kept"} = Mock.get_object(Buckets.recipes(), @key <> ".w256.webp")
    assert {:ok, _} = Mock.get_object(Buckets.recipes(), @key <> ".w1440.webp")
    assert {:ok, _} = Mock.get_object(Buckets.recipes(), "b.jpg.w720.webp")
  end

  test "warm makes every width" do
    :ok = Pictures.warm(@key)

    for w <- Pictures.widths(),
        do: assert({:ok, _} = Mock.get_object(Buckets.recipes(), "#{@key}.w#{w}.webp"))
  end

  test "only Tore's own widths are accepted" do
    assert Pictures.width("720") == 720
    assert Pictures.width(256) == 256
    assert Pictures.width("999") == nil
    assert Pictures.width("72O") == nil
    assert Pictures.width(nil) == nil
  end
end
