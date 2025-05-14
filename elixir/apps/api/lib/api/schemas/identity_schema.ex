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
        provider_id: %Schema{type: :string, description: "Identity Provider ID"},
        provider_identifier: %Schema{type: :string, description: "Identifier from Provider"},
        email: %Schema{type: :string, description: "Email"}
      },
      required: [:id, :actor_id, :provider_id, :provider_identifier, :email],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "actor_id" => "cdfa97e6-cca1-41db-8fc7-864daedb46df",
        "provider_id" => "989f9e96-e348-47ec-ba85-869fcd7adb19",
        "provider_identifier" => "2551705710219359",
        "email" => "foo@bar.com"
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
          "provider_identifier" => "2551705710219359 or foo@bar.com"
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
          "provider_id" => "989f9e96-e348-47ec-ba85-869fcd7adb19",
          "provider_identifier" => "2551705710219359",
          "email" => "foo@bar.com"
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
            "provider_id" => "6472d898-5b98-4c3b-b4b9-d3158c1891be",
            "provider_identifier" => "2551705710219359",
            "email" => "foo@bar.com"
          },
          %{
            "id" => "8a70eb96-e74b-4cdc-91b8-48c05ef74d4c",
            "actor_id" => "38c92cda-1ddb-45b3-9d1a-7efc375e00c1",
            "provider_id" => "04f13eed-4845-47c3-833e-fdd869fab96f",
            "provider_identifier" => "2638957392736483",
            "email" => "baz@bar.com"
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
