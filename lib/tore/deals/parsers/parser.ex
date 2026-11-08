defmodule Tore.Deals.Parsers.Parser do
  @callback hosts() :: [String.t()]
  @callback chain() :: String.t()
  @callback store_name(URI.t()) :: {:ok, String.t()} | {:error, :unsupported_store}
  @doc "The one link for the store, so different links to it are one store."
  @callback canonical_url(URI.t()) :: String.t()
  @callback parse(html :: String.t()) :: {:ok, [map()]} | {:error, term()}
end
