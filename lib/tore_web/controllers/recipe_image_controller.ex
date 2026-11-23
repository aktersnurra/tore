defmodule ToreWeb.RecipeImageController do
  use ToreWeb, :controller

  alias Tore.Recipes
  alias Tore.Recipes.Pictures
  alias ToreWeb.RecipeImage

  # A versioned URL names one picture forever (see `ToreWeb.RecipeImage`): keep it a year and
  # never ask again. An unversioned or stale one is checked each time, which the ETag answers
  # with a 304 without touching storage. The original sent in place of a width that couldn't be
  # made is kept an hour, so the small one is picked up once it can be.
  @forever "private, max-age=31536000, immutable"
  @revalidate "private, no-cache"
  @for_now "private, max-age=3600"

  def show(conn, %{"id" => id} = params) do
    recipe = Recipes.get!(conn.assigns.current_scope, id)
    width = Pictures.width(params["w"])

    with key when is_binary(key) <- recipe.image_path do
      version = RecipeImage.version(key)
      etag = ~s("#{version}#{width && "-#{width}"}")
      current? = params["v"] == version

      conn =
        conn
        |> put_resp_header("etag", etag)
        |> put_resp_header("cache-control", if(current?, do: @forever, else: @revalidate))

      if etag in if_none_match(conn) do
        send_resp(conn, 304, "")
      else
        send_image(conn, key, width, current?)
      end
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp send_image(conn, key, width, current?) do
    case Pictures.get(key, width) do
      {:ok, body, how} ->
        conn
        |> fallback_caching(width, how, current?)
        |> put_resp_content_type(content_type(body), nil)
        |> send_resp(200, body)

      _ ->
        conn
        |> delete_resp_header("etag")
        |> delete_resp_header("cache-control")
        |> send_resp(404, "")
    end
  end

  # Asked for a width and got the original: don't let the browser keep it as that width.
  defp fallback_caching(conn, width, :original, current?) when width != nil do
    conn
    |> delete_resp_header("etag")
    |> put_resp_header("cache-control", if(current?, do: @for_now, else: @revalidate))
  end

  defp fallback_caching(conn, _width, _how, _current?), do: conn

  defp if_none_match(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("W/")))
  end

  # Pictures are stored as `.jpg`, but a generator or a recipe page may hand back PNG or WebP;
  # say what the bytes really are.
  defp content_type(<<0x89, "PNG", _::binary>>), do: "image/png"
  defp content_type(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp content_type(<<"GIF8", _::binary>>), do: "image/gif"
  defp content_type(_), do: "image/jpeg"
end
