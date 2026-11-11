defmodule Tore.Harness.Capsule do
  @moduledoc "A named, typed unit of run context. A struct plus a to_prompt/1."

  @doc "Build the capsule struct from a context map (scope, plan_stream_id, week_start)."
  @callback build(ctx :: map()) :: struct()

  @doc "Render the capsule struct to compact prompt text, or nil if it contributes nothing."
  @callback to_prompt(struct()) :: String.t() | nil
end
