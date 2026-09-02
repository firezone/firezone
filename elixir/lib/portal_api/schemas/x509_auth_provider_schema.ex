defmodule PortalAPI.Schemas.X509AuthProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "X509AuthProvider",
      description: "X.509 Auth Provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Provider ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        name: %Schema{example: "X.509", type: :string, description: "Provider name"},
        context: %Schema{type: :string, description: "Context", enum: ["clients_only"]},
        is_disabled: %Schema{type: :boolean, description: "Whether provider is disabled"},
        inserted_at: %Schema{type: :string, format: :"date-time", description: "Creation timestamp"},
        updated_at: %Schema{type: :string, format: :"date-time", description: "Update timestamp"}
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias PortalAPI.Schemas.X509AuthProvider

    OpenApiSpex.schema(%{
      title: "X509AuthProviderResponse",
      description: "Response schema for a single X.509 Auth Provider",
      type: :object,
      properties: %{data: X509AuthProvider.Schema}
    })
  end
end
