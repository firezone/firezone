defmodule API.Schemas.Resource do
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
        description: %Schema{type: :string, description: "Resource description"},
        type: %Schema{type: :string, description: "Resource type"}
      },
      required: [:name, :type],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Prod DB",
        "address" => "10.0.0.10",
        "description" => "Production Database",
        "type" => "ip"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Resource

    OpenApiSpex.schema(%{
      title: "ResourceRequest",
      description: "POST body for creating a Resource",
      type: :object,
      properties: %{
        resource: %Schema{anyOf: [Resource.Schema]}
      },
      required: [:resource],
      example: %{
        "resource" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "Prod DB",
          "address" => "10.0.0.10",
          "description" => "Production Database",
          "type" => "ip"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Resource

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
          "description" => "Production Database",
          "type" => "ip"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Resource

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
            "description" => "Production Database",
            "type" => "ip"
          },
          %{
            "id" => "3b9451c9-5616-48f8-827f-009ace22d015",
            "name" => "Admin Dashboard",
            "address" => "10.0.0.20",
            "description" => "Production Admin Dashboard",
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
