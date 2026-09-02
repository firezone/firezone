defmodule PortalAPI.Schemas.ExternalIdentity do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "ExternalIdentity",
      description: "External Identity",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "External Identity ID"},
        actor_id: %Schema{type: :string, format: :uuid, description: "Actor ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        issuer: %Schema{example: "https://accounts.google.com",
          type: :string,
          description:
            "Identity issuer URL (e.g., 'https://accounts.google.com', 'https://company.okta.com')"
        },
        directory_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Directory UUID reference"
        },
        email: %Schema{example: "user@example.com", type: :string, description: "Email address, falling back to the IdP identifier when unset"},
        idp_id: %Schema{example: "2551705710219359", type: :string, description: "IDP-specific identifier for this identity"},
        name: %Schema{example: "John Doe", type: :string, description: "Full name"},
        given_name: %Schema{example: "John", type: :string, description: "Given name"},
        family_name: %Schema{example: "Doe", type: :string, description: "Family name"},
        middle_name: %Schema{example: "Quincy", type: :string, description: "Middle name"},
        nickname: %Schema{example: "johnny", type: :string, description: "Nickname"},
        preferred_username: %Schema{example: "jdoe", type: :string, description: "Preferred username"},
        profile: %Schema{example: "https://example.com/users/jdoe", type: :string, description: "Profile URL"},
        picture: %Schema{example: "https://example.com/avatar.jpg", type: :string, description: "Profile picture URL"},
        firezone_avatar_url: %Schema{example: "https://avatars.firezone.dev/u/2551705710219359.png", type: :string, description: "Firezone-hosted avatar URL"},
        synced_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Last sync timestamp"
        },
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        }
      }
    })
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
      required: [:external_identity],
      example: %{
        "external_identity" => %{
          "idp_id" => "2551705710219359 or foo@bar.com"
        }
      }
    })
  end

  defmodule Response do
    use PortalAPI.Schemas.Object
    alias PortalAPI.Schemas.ExternalIdentity

    object(%{
      title: "ExternalIdentityResponse",
      description: "Response schema for single External Identity",
      type: :object,
      properties: %{
        data: ExternalIdentity.Schema
      }
    })
  end

  defmodule ListResponse do
    use PortalAPI.Schemas.Object
    alias PortalAPI.Schemas.ExternalIdentity
    alias PortalAPI.Schemas.PaginationMetadata

    object(%{
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
