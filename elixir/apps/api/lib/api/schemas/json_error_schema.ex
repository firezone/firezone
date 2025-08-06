defmodule API.Schemas.JSONError do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "JSON Error",
    type: :object,
    properties: %{
      error: %Schema{
        type: :object,
        properties: %{
          reason: %Schema{type: :string}
        }
      }
    }
  })
end
