defmodule PortalAPI.Schemas.ExternalIdentity do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ExternalIdentity",
      description: "External Identity",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "External Identity ID"},
        actor_id: %Schema{type: :string, description: "Actor ID"},
        account_id: %Schema{type: :string, description: "Account ID"},
        issuer: %Schema{
          type: :string,
          description:
            "Identity issuer URL (e.g., 'https://accounts.google.com', 'https://company.okta.com')"
        },
        directory_id: %Schema{type: :string, description: "Directory UUID reference"},
        idp_id: %Schema{type: :string, description: "IDP-specific identifier for this identity"},
        name: %Schema{type: :string, description: "Full name"},
        given_name: %Schema{type: :string, description: "Given name"},
        family_name: %Schema{type: :string, description: "Family name"},
        middle_name: %Schema{type: :string, description: "Middle name"},
        nickname: %Schema{type: :string, description: "Nickname"},
        preferred_username: %Schema{type: :string, description: "Preferred username"},
        profile: %Schema{type: :string, description: "Profile URL"},
        picture: %Schema{type: :string, description: "Profile picture URL"},
        firezone_avatar_url: %Schema{type: :string, description: "Firezone-hosted avatar URL"},
        last_synced_at: %Schema{
          type: :string,
          format: :datetime,
          description: "Last sync timestamp"
        },
        inserted_at: %Schema{type: :string, format: :datetime, description: "Creation timestamp"}
      },
      required: [:id, :actor_id, :issuer, :idp_id],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "actor_id" => "cdfa97e6-cca1-41db-8fc7-864daedb46df",
        "account_id" => "5e6f7d8c-9b0a-1c2d-3e4f-5a6b7c8d9e0f",
        "issuer" => "https://accounts.google.com",
        "directory_id" => "9f8e7d6c-5b4a-3c2b-1a0e-9f8e7d6c5b4a",
        "idp_id" => "2551705710219359",
        "name" => "John Doe",
        "given_name" => "John",
        "family_name" => "Doe",
        "picture" => "https://example.com/avatar.jpg",
        "last_synced_at" => "2025-01-15T12:34:56.789Z",
        "inserted_at" => "2025-01-15T12:34:56.789Z"
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
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.ExternalIdentity

    OpenApiSpex.schema(%{
      title: "ExternalIdentityResponse",
      description: "Response schema for single External Identity",
      type: :object,
      properties: %{
        data: ExternalIdentity.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "actor_id" => "cdfa97e6-cca1-41db-8fc7-864daedb46df",
          "account_id" => "5e6f7d8c-9b0a-1c2d-3e4f-5a6b7c8d9e0f",
          "issuer" => "https://accounts.google.com",
          "directory_id" => "9f8e7d6c-5b4a-3c2b-1a0e-9f8e7d6c5b4a",
          "idp_id" => "2551705710219359",
          "name" => "John Doe",
          "given_name" => "John",
          "family_name" => "Doe",
          "picture" => "https://example.com/avatar.jpg",
          "last_synced_at" => "2025-01-15T12:34:56.789Z",
          "inserted_at" => "2025-01-15T12:34:56.789Z"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.ExternalIdentity

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
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "actor_id" => "8f44a02b-b8eb-406f-8202-4274bf60ebd0",
            "account_id" => "5e6f7d8c-9b0a-1c2d-3e4f-5a6b7c8d9e0f",
            "issuer" => "https://accounts.google.com",
            "directory_id" => "9f8e7d6c-5b4a-3c2b-1a0e-9f8e7d6c5b4a",
            "idp_id" => "2551705710219359",
            "name" => "John Doe",
            "given_name" => "John",
            "family_name" => "Doe",
            "picture" => "https://example.com/avatar1.jpg",
            "last_synced_at" => "2025-01-15T12:34:56.789Z",
            "inserted_at" => "2025-01-15T12:34:56.789Z"
          },
          %{
            "id" => "8a70eb96-e74b-4cdc-91b8-48c05ef74d4c",
            "actor_id" => "38c92cda-1ddb-45b3-9d1a-7efc375e00c1",
            "account_id" => "5e6f7d8c-9b0a-1c2d-3e4f-5a6b7c8d9e0f",
            "issuer" => "https://company.okta.com",
            "directory_id" => "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
            "idp_id" => "2638957392736483",
            "name" => "Jane Smith",
            "given_name" => "Jane",
            "family_name" => "Smith",
            "picture" => "https://example.com/avatar2.jpg",
            "last_synced_at" => "2025-01-15T11:22:33.456Z",
            "inserted_at" => "2025-01-15T11:22:33.456Z"
          }
        ],
        "metadata" => %{
          "limit" => 10,
          "total" => 100,
          "prev_page" => "123123425",
          "next_page" => "98776234123"
        }
      }
    })
  end
end
