defmodule ToreWeb.RecipeImageController do
  use ToreWeb, :controller

  alias Tore.ImageResize
  alias Tore.Recipes
  alias Tore.Recipes.Pictures
  alias ToreWeb.RecipeImage

  # A versioned URL names one picture forever (see `ToreWeb.RecipeImage`): keep it a year and
  # never ask again. An unversioned or stale one is checked each time, which the ETag answers
  # with a 304 without touching storage. The original sent in place of a width is never kept as
  # that width for long: five minutes while the width is still being made, an hour when it can't
  # be (no vips, not a photo), so it's picked up once it can.
  @forever "private, max-age=31536000, immutable"
  @revalidate "private, no-cache"
  @pending "private, max-age=300"
  @for_now "private, max-age=3600"

  def show(conn, %{"id" => id} = params) do
    width = Pictures.width(params["w"])

    with key when is_binary(key) <- Recipes.image_path!(conn.assigns.current_scope, id) do
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
        |> put_resp_content_type(body |> ImageResize.format() |> ImageResize.content_type(), nil)
        |> send_resp(200, body)

      _ ->
        conn
        |> delete_resp_header("etag")
        |> delete_resp_header("cache-control")
        |> send_resp(404, "")
    end
  end

  # Asked for a width and got the original: don't let the browser keep it as that width.
  defp fallback_caching(conn, width, how, current?)
       when width != nil and how in [:pending, :original] do
    cache_control =
      cond do
        not current? -> @revalidate
        how == :pending -> @pending
        true -> @for_now
      end

    conn
    |> delete_resp_header("etag")
    |> put_resp_header("cache-control", cache_control)
  end

  defp fallback_caching(conn, _width, _how, _current?), do: conn

  defp if_none_match(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("W/")))
  end
end
