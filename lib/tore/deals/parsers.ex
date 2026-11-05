defmodule Tore.Deals.Parsers do
  @moduledoc """
  Picks the deal parser for a store's link. Adding a store means adding a module
  to `@backends`. Only https links on a backend's hosts get a parser, so a pasted
  link can't point Tore at anything else.
  """

  @backends [Tore.Deals.Parsers.ICA]

  @spec for_url(String.t()) :: {:ok, module()} | {:error, :unsupported_store}
  def for_url(url) when is_binary(url) do
    with %URI{scheme: "https", host: host, port: 443} <- URI.parse(url),
         parser when not is_nil(parser) <- Enum.find(@backends, &(host in &1.hosts())) do
      {:ok, parser}
    else
      _ -> {:error, :unsupported_store}
    end
  end
end
