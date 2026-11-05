defmodule Tore.Deals.Parsers.Parser do
  @callback hosts() :: [String.t()]
  @callback chain() :: String.t()
  @callback store_name(URI.t()) :: {:ok, String.t()} | {:error, :unsupported_store}
  @callback parse(html :: String.t()) :: {:ok, [map()]} | {:error, term()}
end
