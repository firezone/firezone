defmodule API.Schemas.SiteToken do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SiteToken",
      description: "Site Token",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Site Token ID"},
        token: %Schema{type: :string, description: "Site Token"}
      },
      required: [:id, :token],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "token" => "secret-token-here"
      }
    })
  end

  defmodule NewToken do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.SiteToken

    OpenApiSpex.schema(%{
      title: "NewSiteTokenResponse",
      description: "Response schema for a new Site Token",
      type: :object,
      properties: %{
        data: SiteToken.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "token" => "secret-token-here"
        }
      }
    })
  end

  defmodule DeletedToken do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.SiteToken

    OpenApiSpex.schema(%{
      title: "DeletedSiteTokenResponse",
      description: "Response schema for a new Site Token",
      type: :object,
      properties: %{
        data: SiteToken.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205"
        }
      }
    })
  end

  defmodule DeletedTokens do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DeletedSiteTokenListResponse",
      description: "Response schema for deleted Site Tokens",
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
