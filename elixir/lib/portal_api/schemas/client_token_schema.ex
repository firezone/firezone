defmodule PortalAPI.Schemas.ClientToken do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ClientToken",
      description: "Client Token metadata",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Client Token ID"},
        actor_id: %Schema{type: :string, format: :uuid, description: "Actor ID"},
        expires_at: %Schema{type: :string, format: :"date-time", description: "Expiration"},
        inserted_at: %Schema{type: :string, format: :"date-time", description: "Creation timestamp"},
        updated_at: %Schema{type: :string, format: :"date-time", description: "Update timestamp"}
      },
      required: [:id, :actor_id, :expires_at, :inserted_at, :updated_at],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "actor_id" => "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "expires_at" => "2025-01-15T12:34:56.789Z",
        "inserted_at" => "2025-01-15T12:34:56.789Z",
        "updated_at" => "2025-01-15T12:34:56.789Z"
      }
    })
  end

  defmodule CreateSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ClientTokenCreate",
      description: "Client Token attributes",
      type: :object,
      properties: %{
        expires_at: %Schema{type: :string, format: :"date-time", description: "Expiration"}
      },
      required: [:expires_at],
      example: %{
        "expires_at" => "2025-01-15T12:34:56.789Z"
      }
    })
  end

  defmodule ResponseSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.ClientToken

    OpenApiSpex.schema(%{
      title: "ClientTokenResponse",
      description: "Client Token response",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Client Token ID"},
        actor_id: %Schema{type: :string, format: :uuid, description: "Actor ID"},
        expires_at: %Schema{type: :string, format: :"date-time", description: "Expiration"},
        inserted_at: %Schema{type: :string, format: :"date-time", description: "Creation timestamp"},
        updated_at: %Schema{type: :string, format: :"date-time", description: "Update timestamp"},
        token: %Schema{type: :string, description: "Encoded token secret"}
      },
      required: [:id, :actor_id, :expires_at, :inserted_at, :updated_at, :token],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "actor_id" => "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "expires_at" => "2025-01-15T12:34:56.789Z",
        "inserted_at" => "2025-01-15T12:34:56.789Z",
        "updated_at" => "2025-01-15T12:34:56.789Z",
        "token" => "secret-token-here"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias PortalAPI.Schemas.ClientToken

    OpenApiSpex.schema(%{
      title: "ClientTokenRequest",
      description: "POST body for creating a Client Token",
      type: :object,
      properties: %{
        client_token: ClientToken.CreateSchema
      },
      required: [:client_token],
      example: %{
        "client_token" => %{
          "expires_at" => "2025-01-15T12:34:56.789Z"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias PortalAPI.Schemas.ClientToken

    OpenApiSpex.schema(%{
      title: "ClientTokenCreateResponse",
      description: "Response schema for a new Client Token",
      type: :object,
      properties: %{
        data: ClientToken.ResponseSchema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "actor_id" => "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "expires_at" => "2025-01-15T12:34:56.789Z",
          "inserted_at" => "2025-01-15T12:34:56.789Z",
          "updated_at" => "2025-01-15T12:34:56.789Z",
          "token" => "secret-token-here"
        }
      }
    })
  end

  defmodule ShowResponse do
    require OpenApiSpex
    alias PortalAPI.Schemas.ClientToken

    OpenApiSpex.schema(%{
      title: "ClientTokenResponse",
      description: "Response schema for Client Token metadata",
      type: :object,
      properties: %{
        data: ClientToken.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "actor_id" => "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "expires_at" => "2025-01-15T12:34:56.789Z",
          "inserted_at" => "2025-01-15T12:34:56.789Z",
          "updated_at" => "2025-01-15T12:34:56.789Z"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.ClientToken
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "ClientTokenListResponse",
      description: "Response schema for multiple Client Tokens",
      type: :object,
      properties: %{
        data: %Schema{description: "Client Token metadata", type: :array, items: ClientToken.Schema},
        metadata: PaginationMetadata
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "actor_id" => "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "expires_at" => "2025-01-15T12:34:56.789Z",
            "inserted_at" => "2025-01-15T12:34:56.789Z",
            "updated_at" => "2025-01-15T12:34:56.789Z"
          }
        ],
        "metadata" => %{
          "limit" => 10,
          "count" => 1,
          "prev_page" => nil,
          "next_page" => nil
        }
      }
    })
  end

  defmodule DeletedResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DeletedClientTokenResponse",
      description: "Response schema for a deleted Client Token",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string, format: :uuid, description: "Client Token ID"}
          },
          required: [:id]
        }
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205"
        }
      }
    })
  end

  defmodule DeletedAllResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DeletedClientTokensResponse",
      description: "Response schema for deleted Client Tokens",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            deleted_count: %Schema{
              type: :integer,
              description: "Number of tokens that were deleted"
            }
          },
          required: [:deleted_count]
        }
      },
      example: %{
        "data" => %{
          "deleted_count" => 3
        }
      }
    })
  end
end
