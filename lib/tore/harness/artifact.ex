defmodule Tore.Harness.Artifact do
  @type kind :: String.t()
  @type t :: struct()

  @callback kind() :: kind()
  @callback to_json(t()) :: map()
  @callback from_json(map()) :: t()

  @spec to_json(t()) :: map()
  def to_json(%mod{} = artifact), do: Map.put(mod.to_json(artifact), "__kind__", mod.kind())
end
