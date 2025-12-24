defmodule PortalAPI.Schemas.Account do
  alias OpenApiSpex.Schema

  defmodule LimitSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "AccountLimit",
      description: "Account limit with usage information",
      type: :object,
      properties: %{
        used: %Schema{type: :integer, description: "Current usage count"},
        available: %Schema{type: :integer, description: "Remaining available count"},
        total: %Schema{type: :integer, description: "Total allowed count"}
      },
      required: [:used, :available, :total]
    })
  end

  defmodule LimitsSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "AccountLimits",
      description: "Account limits and usage information",
      type: :object,
      properties: %{
        users: PortalAPI.Schemas.Account.LimitSchema,
        monthly_active_users: PortalAPI.Schemas.Account.LimitSchema,
        service_accounts: PortalAPI.Schemas.Account.LimitSchema,
        account_admin_users: PortalAPI.Schemas.Account.LimitSchema,
        sites: PortalAPI.Schemas.Account.LimitSchema
      }
    })
  end

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Account",
      description: "Account schema",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Account ID"},
        slug: %Schema{type: :string, description: "Account slug"},
        name: %Schema{type: :string, description: "Account name"},
        legal_name: %Schema{type: :string, description: "Account legal name"},
        limits: PortalAPI.Schemas.Account.LimitsSchema
      },
      required: [:id, :slug, :name]
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "AccountResponse",
      description: "Response schema for Account",
      type: :object,
      properties: %{
        data: PortalAPI.Schemas.Account.Schema
      },
      required: [:data]
    })
  end
end
