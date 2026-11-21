defmodule Tore.Deals.Logo do
  @moduledoc """
  A store's logo, from the page Tore reads its offers from: the icon the site gives phones for
  their home screen (`apple-touch-icon`), the largest there is, or else its largest icon. Kept as
  a link on the store, so each morning's read keeps it current.
  """

  @doc "The logo `html` (the page at `page_url`) links to, as a whole link, or nil."
  @spec find(String.t(), String.t()) :: String.t() | nil
  def find(html, page_url) do
    links =
      case Floki.parse_document(html) do
        {:ok, document} -> Floki.find(document, "link[rel][href]")
        {:error, _} -> []
      end

    Enum.find_value(["apple-touch-icon", "icon"], fn rel ->
      links
      |> Enum.filter(&(rel in rels(&1)))
      |> Enum.max_by(&size/1, fn -> nil end)
      |> case do
        nil -> nil
        link -> page_url |> URI.merge(attribute(link, "href")) |> URI.to_string()
      end
    end)
  end

  defp rels(link), do: link |> attribute("rel") |> String.downcase() |> String.split()

  defp size(link) do
    case Integer.parse(attribute(link, "sizes") || "") do
      {pixels, _} -> pixels
      :error -> 0
    end
  end

  defp attribute(link, name), do: link |> Floki.attribute(name) |> List.first()
end
