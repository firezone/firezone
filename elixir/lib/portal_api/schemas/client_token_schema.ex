defmodule PortalAPI.Schemas.ClientToken do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.ClientToken,
             internal: [
               :account_id,
               :auth_provider_id,
               :auth_provider_name,
               :auth_provider_type,
               :last_used_device,
               :online?
             ]}
    OpenApiSpex.schema(%{
      title: "ClientToken",
      description: "Client Token metadata",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Client Token ID"
        },
        actor_id: %Schema{
          example: "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Actor ID"
        },
        expires_at: %Schema{
          example: "2025-01-15T12:34:56.789Z",
          type: :string,
          format: :"date-time",
          description: "Expiration"
        },
        inserted_at: %Schema{
          example: "2025-01-15T12:34:56.789Z",
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{
          example: "2025-01-15T12:34:56.789Z",
          type: :string,
          format: :"date-time",
          description: "Update timestamp"
        }
      },
      required: [:actor_id, :expires_at, :id, :inserted_at, :updated_at]
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
        expires_at: %Schema{
          example: "2025-01-15T12:34:56.789Z",
          type: :string,
          format: :"date-time",
          description: "Expiration"
        }
      },
      required: [:expires_at]
    })
  end

  defmodule ResponseSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.ClientToken

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.ClientToken,
             internal: [
               :account_id,
               :auth_provider_id,
               :auth_provider_name,
               :auth_provider_type,
               :last_used_device,
               :online?
             ]}
    OpenApiSpex.schema(%{
      title: "ClientTokenWithSecret",
      description:
        "Client Token as returned when it is created, including the encoded secret. " <>
          "The secret is shown once and cannot be retrieved later.",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Client Token ID"
        },
        actor_id: %Schema{
          example: "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Actor ID"
        },
        expires_at: %Schema{
          example: "2025-01-15T12:34:56.789Z",
          type: :string,
          format: :"date-time",
          description: "Expiration"
        },
        inserted_at: %Schema{
          example: "2025-01-15T12:34:56.789Z",
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{
          example: "2025-01-15T12:34:56.789Z",
          type: :string,
          format: :"date-time",
          description: "Update timestamp"
        },
        token: %Schema{
          example: "secret-token-here",
          type: :string,
          description: "Encoded token secret"
        }
      },
      required: [:actor_id, :expires_at, :id, :inserted_at, :token, :updated_at]
    })

    # Only a token just created carries the secret fragment the encoded token is
    # built from, which is why this is a separate schema from the read one.
    def map(%Portal.ClientToken{} = token, _map) do
      %{token: Portal.Authentication.encode_fragment!(token)}
    end
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
      required: [:client_token]
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
      }
    })
  end

  defmodule ShowResponse do
    require OpenApiSpex
    alias PortalAPI.Schemas.ClientToken

    OpenApiSpex.schema(%{
      title: "ClientTokenShowResponse",
      description: "Response schema for Client Token metadata",
      type: :object,
      properties: %{
        data: ClientToken.Schema
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
        data: %Schema{
          example: [
            %{
              "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
              "actor_id" => "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
              "expires_at" => "2025-01-15T12:34:56.789Z",
              "inserted_at" => "2025-01-15T12:34:56.789Z",
              "updated_at" => "2025-01-15T12:34:56.789Z"
            }
          ],
          description: "Client Token metadata",
          type: :array,
          items: ClientToken.Schema
        },
        metadata: PaginationMetadata
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
            id: %Schema{
              example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
              type: :string,
              format: :uuid,
              description: "Client Token ID"
            }
          },
          required: [:id]
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
              example: 3,
              type: :integer,
              description: "Number of tokens that were deleted"
            }
          },
          required: [:deleted_count]
        }
      }
    })
  end
end
