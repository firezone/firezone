defmodule PortalAPI.Schemas.Site do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Site",
      description: "Site",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Site ID"},
        name: %Schema{type: :string, description: "Site Name"}
      },
      required: [:id, :name],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "vpc-us-east"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Site

    OpenApiSpex.schema(%{
      title: "SiteRequest",
      description: "POST body for creating a Site",
      type: :object,
      properties: %{
        site: Site.Schema
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
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "vpc-us-east"
          },
          %{
            "id" => "6301d7d2-4938-4123-87de-282c01cca656",
            "name" => "vpc-us-west"
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
