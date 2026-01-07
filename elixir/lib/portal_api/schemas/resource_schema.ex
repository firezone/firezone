defmodule PortalAPI.Schemas.Resource do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Resource",
      description: "Resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Resource ID"},
        name: %Schema{type: :string, description: "Resource name"},
        address: %Schema{type: :string, description: "Resource address"},
        address_description: %Schema{type: :string, description: "Resource address description"},
        type: %Schema{
          type: :string,
          description: "Resource type",
          enum: ["cidr", "ip", "dns"]
        },
        ip_stack: %Schema{
          type: :string,
          description: "IP stack type. Only supported for DNS resources.",
          enum: ["ipv4_only", "ipv6_only", "dual"]
        },
        site_id: %Schema{
          title: "Site ID",
          description: "Site to connect the Resource to",
          type: :string
        }
      },
      required: [:name, :type, :site_id],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Prod DB",
        "address" => "10.0.0.10",
        "address_description" => "Production Database",
        "type" => "ip"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Resource

    OpenApiSpex.schema(%{
      title: "ResourceRequest",
      description: "POST body for creating a Resource",
      type: :object,
      properties: %{
        resource: %Schema{properties: Resource.Schema.schema().properties}
      },
      required: [:resource],
      example: %{
        "resource" => %{
          "name" => "Prod DB",
          "address" => "10.0.0.10",
          "address_description" => "Production Database",
          "type" => "ip",
          "site_id" => "0642e09d-b3a2-47e4-9cd1-c2195faeeb67"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Resource

    OpenApiSpex.schema(%{
      title: "ResourceResponse",
      description: "Response schema for single Resource",
      type: :object,
      properties: %{
        data: Resource.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "Prod DB",
          "address" => "10.0.0.10",
          "address_description" => "Production Database",
          "type" => "ip"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Resource

    OpenApiSpex.schema(%{
      title: "ResourceListResponse",
      description: "Response schema for multiple Resources",
      type: :object,
      properties: %{
        data: %Schema{description: "Resource details", type: :array, items: Resource.Schema},
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "Prod DB",
            "address" => "10.0.0.10",
            "address_description" => "Production Database",
            "type" => "ip"
          },
          %{
            "id" => "3b9451c9-5616-48f8-827f-009ace22d015",
            "name" => "Admin Dashboard",
            "address" => "10.0.0.20",
            "address_description" => "Production Admin Dashboard",
            "type" => "ip"
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
