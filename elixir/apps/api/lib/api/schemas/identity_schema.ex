defmodule API.Schemas.Identity do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Identity",
      description: "Identity",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Identity ID"},
        actor_id: %Schema{type: :string, description: "Actor ID"},
        issuer: %Schema{
          type: :string,
          description: "Identity issuer (e.g., 'firezone', 'google', 'okta')"
        },
        idp_id: %Schema{type: :string, description: "IDP-specific identifier for this identity"},
        name: %Schema{type: :string, description: "Full name"},
        given_name: %Schema{type: :string, description: "Given name"},
        family_name: %Schema{type: :string, description: "Family name"},
        picture: %Schema{type: :string, description: "Profile picture URL"},
        last_seen_at: %Schema{
          type: :string,
          format: :datetime,
          description: "Last seen timestamp"
        }
      },
      required: [:id, :actor_id, :issuer, :idp_id],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "actor_id" => "cdfa97e6-cca1-41db-8fc7-864daedb46df",
        "issuer" => "google",
        "idp_id" => "2551705710219359",
        "name" => "John Doe",
        "picture" => "https://example.com/avatar.jpg"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Identity

    OpenApiSpex.schema(%{
      title: "IdentityRequest",
      description: "POST body for creating a Identity",
      type: :object,
      properties: %{
        identity: Identity.Schema
      },
      required: [:identity],
      example: %{
        "identity" => %{
          "idp_id" => "2551705710219359 or foo@bar.com"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Identity

    OpenApiSpex.schema(%{
      title: "IdentityResponse",
      description: "Response schema for single Identity",
      type: :object,
      properties: %{
        data: Identity.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "actor_id" => "cdfa97e6-cca1-41db-8fc7-864daedb46df",
          "issuer" => "google",
          "idp_id" => "2551705710219359",
          "name" => "John Doe",
          "picture" => "https://example.com/avatar.jpg"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Identity

    OpenApiSpex.schema(%{
      title: "IdentityListResponse",
      description: "Response schema for multiple Identities",
      type: :object,
      properties: %{
        data: %Schema{description: "Identity details", type: :array, items: Identity.Schema},
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "actor_id" => "8f44a02b-b8eb-406f-8202-4274bf60ebd0",
            "issuer" => "google",
            "idp_id" => "2551705710219359",
            "name" => "John Doe",
            "picture" => "https://example.com/avatar1.jpg"
          },
          %{
            "id" => "8a70eb96-e74b-4cdc-91b8-48c05ef74d4c",
            "actor_id" => "38c92cda-1ddb-45b3-9d1a-7efc375e00c1",
            "issuer" => "okta",
            "idp_id" => "2638957392736483",
            "name" => "Jane Smith",
            "picture" => "https://example.com/avatar2.jpg"
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
