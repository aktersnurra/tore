defmodule ToreWeb.RecipeImage do
  @moduledoc """
  Where a recipe's picture is served: a signed link that needs no session and no database.

  A picture's URL carries its storage key and a signature of it:
  `/images/pictures/<signature>/<key, base64url>?w=720`. Only Tore can make the signature (it's
  an HMAC under a secret derived from the endpoint's `secret_key_base`), so a link is only ever
  one Tore put on a household's page, and serving it is a check of the signature and one read
  from storage, beside the single SQLite connection rather than through it.

  Each picture is stored under its own key (a new UUID every time one is drawn or fetched), and
  the signature of a key never changes, so a URL names one picture forever: the browser keeps it
  a year without asking again, and a new picture is a new URL.

  `/images/recipes/:id` (behind login, by recipe) stays for what only knows a recipe's id.
  """

  use ToreWeb, :verified_routes

  @type recipe :: %{id: integer(), image_path: String.t() | nil}

  @doc """
  The picture's signed URL: the original, or `width` wide (one of
  `Tore.Recipes.Pictures.widths/0`). Nil when the recipe has no picture.
  """
  @spec path(recipe(), pos_integer() | nil) :: String.t() | nil
  def path(recipe, width \\ nil)
  def path(%{image_path: nil}, _width), do: nil

  def path(%{image_path: key}, nil),
    do: ~p"/images/pictures/#{sign(key)}/#{Base.url_encode64(key, padding: false)}"

  def path(%{image_path: key}, width),
    do: ~p"/images/pictures/#{sign(key)}/#{Base.url_encode64(key, padding: false)}?#{[w: width]}"

  @doc "A `srcset` of the card and big widths, for a picture whose shown size varies with the screen."
  @spec srcset(recipe()) :: String.t() | nil
  def srcset(%{image_path: nil}), do: nil

  def srcset(recipe),
    do: Enum.map_join([720, 1440], ", ", &"#{__MODULE__.path(recipe, &1)} #{&1}w")

  @doc "The storage key a signed URL's parts name, when the signature is Tore's."
  @spec verify(String.t(), String.t()) :: {:ok, String.t()} | :error
  def verify(signature, encoded_key) when is_binary(signature) and is_binary(encoded_key) do
    with {:ok, key} <- Base.url_decode64(encoded_key, padding: false),
         true <- Plug.Crypto.secure_compare(sign(key), signature) do
      {:ok, key}
    else
      _ -> :error
    end
  end

  @doc "A short, stable version for a stored key: the ETag of its picture."
  @spec version(String.t()) :: String.t()
  def version(key) when is_binary(key) do
    :crypto.hash(:sha256, key) |> binary_part(0, 8) |> Base.url_encode64(padding: false)
  end

  defp sign(key) do
    :crypto.mac(:hmac, :sha256, secret(), key)
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  # Derived once per secret_key_base (a key derivation is too slow to run per picture).
  defp secret do
    base = ToreWeb.Endpoint.config(:secret_key_base)
    id = {__MODULE__, :crypto.hash(:sha256, base)}

    case :persistent_term.get(id, nil) do
      nil ->
        secret = Plug.Crypto.KeyGenerator.generate(base, "recipe picture", length: 32)
        :persistent_term.put(id, secret)
        secret

      secret ->
        secret
    end
  end
end
