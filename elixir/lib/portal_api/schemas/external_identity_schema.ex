defmodule PortalAPI.Schemas.ExternalIdentity do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.ExternalIdentity, internal: [:directory_name, :updated_at]}
    OpenApiSpex.schema(%{
      title: "ExternalIdentity",
      description: "External Identity",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "External Identity ID"
        },
        actor_id: %Schema{
          example: "cdfa97e6-cca1-41db-8fc7-864daedb46df",
          type: :string,
          format: :uuid,
          description: "Actor ID"
        },
        account_id: %Schema{
          example: "5e6f7d8c-9b0a-1c2d-3e4f-5a6b7c8d9e0f",
          type: :string,
          format: :uuid,
          description: "Account ID"
        },
        issuer: %Schema{
          example: "https://accounts.google.com",
          type: :string,
          description:
            "Identity issuer URL (e.g., 'https://accounts.google.com', 'https://company.okta.com')"
        },
        directory_id: %Schema{
          example: "9f8e7d6c-5b4a-3c2b-1a0e-9f8e7d6c5b4a",
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Directory UUID reference"
        },
        email: %Schema{
          example: "john.doe@example.com",
          type: :string,
          description: "Email address, falling back to the IdP identifier when unset"
        },
        idp_id: %Schema{
          example: "2551705710219359",
          type: :string,
          description: "IDP-specific identifier for this identity"
        },
        name: %Schema{
          example: "John Doe",
          type: :string,
          nullable: true,
          description: "Full name"
        },
        given_name: %Schema{
          example: "John",
          type: :string,
          nullable: true,
          description: "Given name"
        },
        family_name: %Schema{
          example: "Doe",
          type: :string,
          nullable: true,
          description: "Family name"
        },
        middle_name: %Schema{
          example: nil,
          type: :string,
          nullable: true,
          description: "Middle name"
        },
        nickname: %Schema{example: nil, type: :string, nullable: true, description: "Nickname"},
        preferred_username: %Schema{
          example: "jdoe",
          type: :string,
          nullable: true,
          description: "Preferred username"
        },
        profile: %Schema{example: nil, type: :string, nullable: true, description: "Profile URL"},
        picture: %Schema{
          example: "https://example.com/avatar.jpg",
          type: :string,
          nullable: true,
          description: "Profile picture URL"
        },
        firezone_avatar_url: %Schema{
          example: "https://avatars.firezone.dev/u/2551705710219359.png",
          type: :string,
          nullable: true,
          description: "Firezone-hosted avatar URL"
        },
        synced_at: %Schema{
          example: "2025-01-15T10:30:00Z",
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Last sync timestamp"
        },
        inserted_at: %Schema{
          example: "2025-01-01T00:00:00Z",
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        }
      },
      required: [
        :account_id,
        :actor_id,
        :directory_id,
        :email,
        :family_name,
        :firezone_avatar_url,
        :given_name,
        :id,
        :idp_id,
        :inserted_at,
        :issuer,
        :middle_name,
        :name,
        :nickname,
        :picture,
        :preferred_username,
        :profile,
        :synced_at
      ]
    })

    def map(%Portal.ExternalIdentity{} = identity, _map) do
      %{
        email: identity.email || identity.idp_id,
        idp_id: identity.idp_id |> String.split(":", parts: 2) |> List.last(),
        synced_at: synced_at(identity.sync_state)
      }
    end

    defp synced_at(%Portal.ExternalIdentitySyncState{synced_at: synced_at}), do: synced_at
    defp synced_at(nil), do: nil
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.ExternalIdentity

    OpenApiSpex.schema(%{
      title: "ExternalIdentityRequest",
      description: "POST body for creating an External Identity",
      type: :object,
      properties: %{
        external_identity: ExternalIdentity.Schema
      },
      required: [:external_identity]
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.ExternalIdentity

    OpenApiSpex.schema(%{
      title: "ExternalIdentityResponse",
      description: "Response schema for single External Identity",
      type: :object,
      properties: %{
        data: ExternalIdentity.Schema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.ExternalIdentity
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "ExternalIdentityListResponse",
      description: "Response schema for multiple External Identities",
      type: :object,
      properties: %{
        data: %Schema{
          description: "External Identity details",
          type: :array,
          items: ExternalIdentity.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
