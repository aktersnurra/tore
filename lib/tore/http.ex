defmodule Tore.HTTP do
  @callback fetch(url :: String.t()) :: {:ok, binary()} | {:error, term()}
  @doc "The same, with headers a site needs, such as the user agent ICA lets through."
  @callback fetch(url :: String.t(), headers :: [{String.t(), String.t()}]) ::
              {:ok, binary()} | {:error, term()}
end
