defmodule API.Schemas.Account do
  alias OpenApiSpex.Schema

  defmodule GetSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "AccountGet",
      description: "Get schema for retrieving Account details",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Account ID"},
        slug: %Schema{type: :string, description: "Account slug"},
        name: %Schema{type: :string, description: "Account name"},
        legal_name: %Schema{type: :string, description: "Account legal name"},

      },
  end
end
