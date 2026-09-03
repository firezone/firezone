defmodule PortalAPI.Schemas.Site do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder, for: Portal.Site}
    OpenApiSpex.schema(%{
      title: "Site",
      description: "Site",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Site ID"},
        name: %Schema{type: :string, description: "Site Name"}
      },
      required: [:id, :name],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "vpc-us-east"
      }
    })

    # Struct fields deliberately withheld from the API.
    def internal do
      [
        :account_id,
        :health_threshold,
        :inserted_at,
        :managed_by,
        :updated_at
      ]
    end
  end

  defmodule CreateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SiteCreateRequest",
      description: "POST body for creating a Site",
      type: :object,
      properties: %{
        site: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Site Name"}
          },
          required: [:name]
        }
      },
      required: [:site],
      example: %{
        "site" => %{
          "name" => "vpc-us-east"
        }
      }
    })
  end

  defmodule UpdateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SiteUpdateRequest",
      description:
        "PATCH/PUT body for updating a Site. All fields are optional; omitted fields keep " <>
          "their current value.",
      type: :object,
      properties: %{
        site: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Site Name"}
          }
        }
      },
      required: [:site],
      example: %{
        "site" => %{
          "name" => "vpc-us-east"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Site

    OpenApiSpex.schema(%{
      title: "SiteResponse",
      description: "Response schema for single Site",
      type: :object,
      properties: %{
        data: Site.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "vpc-us-east"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Site
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "SiteListResponse",
      description: "Response schema for multiple Sites",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Site details",
          type: :array,
          items: Site.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
