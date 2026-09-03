defmodule PortalAPI.Encoder do
  @moduledoc """
  Builds the JSON payload for a struct from its response schema.

  The payload has exactly the schema's properties. Each value comes from
  `extras` when the caller supplied it, otherwise from the schema's `value/2`.
  Keys the schema lists as optional are dropped when nil.
  """

  alias PortalAPI.Schema

  @spec encode(module(), struct(), map()) :: map()
  def encode(schema, struct, extras \\ %{}) do
    optional = Schema.optional(schema)

    schema.schema().properties
    |> Map.keys()
    |> Map.new(fn field -> {field, value(schema, field, struct, extras)} end)
    |> Map.merge(extras)
    |> Map.reject(fn {field, value} -> field in optional and is_nil(value) end)
  end

  defp value(schema, field, struct, extras) do
    case extras do
      %{^field => value} -> value
      _ -> Schema.value(schema, field, struct)
    end
  end
end
