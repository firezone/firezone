defmodule PortalAPI.Schemas.GatewayToken do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GatewayToken",
      description: "Gateway Token",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Gateway Token ID"},
        token: %Schema{type: :string, description: "Gateway Token"}
      },
      required: [:id, :token],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "token" => "secret-token-here"
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias PortalAPI.Schemas.GatewayToken

    OpenApiSpex.schema(%{
      title: "GatewayTokenResponse",
      description: "Response schema for a new Gateway Token",
      type: :object,
      properties: %{
        data: GatewayToken.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "token" => "secret-token-here"
        }
      }
    })
  end

  defmodule MetadataSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "GatewayTokenMetadata",
      description:
        "Gateway Token metadata. Token values cannot be retrieved after creation.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Gateway Token ID"},
        site_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Site whose Gateways may all use this token. " <>
              "Null when the token is bound to a single Gateway."
        },
        gateway_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Gateway this token is bound to. " <>
              "Null when any Gateway in the Site may use it."
        },
        rotated_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description:
            "When the token was rotated out. It stays usable for a grace period after this, " <>
              "until its replacement is first used."
        },
        inserted_at: %Schema{type: :string, format: :"date-time", description: "Creation timestamp"}
      },
      required: [:id, :site_id, :gateway_id, :rotated_at, :inserted_at],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "site_id" => nil,
        "gateway_id" => "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "rotated_at" => nil,
        "inserted_at" => "2025-01-15T12:34:56.789Z"
      }
    })
  end

  defmodule ShowResponse do
    require OpenApiSpex
    alias PortalAPI.Schemas.GatewayToken

    OpenApiSpex.schema(%{
      title: "GatewayTokenShowResponse",
      description:
        "Response schema for Gateway Token metadata. " <>
          "Token values cannot be retrieved after creation.",
      type: :object,
      properties: %{
        data: GatewayToken.MetadataSchema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "site_id" => nil,
          "gateway_id" => "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "rotated_at" => nil,
          "inserted_at" => "2025-01-15T12:34:56.789Z"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.GatewayToken
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "GatewayTokenListResponse",
      description:
        "Response schema for multiple Gateway Tokens. " <>
          "Token values cannot be retrieved after creation.",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Gateway Token metadata",
          type: :array,
          items: GatewayToken.MetadataSchema
        },
        metadata: PaginationMetadata
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "site_id" => nil,
            "gateway_id" => "43a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "rotated_at" => nil,
            "inserted_at" => "2025-01-15T12:34:56.789Z"
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
      title: "DeletedGatewayTokenResponse",
      description: "Response schema for a deleted Gateway Token",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string, format: :uuid, description: "Gateway Token ID"}
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
      title: "DeletedGatewayTokensResponse",
      description: "Response schema for deleted Gateway Tokens",
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
          "deleted_count" => 5
        }
      }
    })
  end
end
