defmodule API.Schemas.Group do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Group",
      description: "Group",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Group ID"},
        name: %Schema{type: :string, description: "Group Name"}
      },
      required: [:id, :name],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Engineering"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Group

    OpenApiSpex.schema(%{
      title: "GroupRequest",
      description: "POST body for creating an Group",
      type: :object,
      properties: %{
        group: Group.Schema
      },
      required: [:group],
      example: %{
        "group" => %{
          "name" => "Engineering"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Group

    OpenApiSpex.schema(%{
      title: "GroupResponse",
      description: "Response schema for single Group",
      type: :object,
      properties: %{
        data: Group.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "Engineering"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Group

    OpenApiSpex.schema(%{
      title: "GroupListResponse",
      description: "Response schema for multiple Groups",
      type: :object,
      properties: %{
        data: %Schema{description: "Group details", type: :array, items: Group.Schema},
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "Engineering"
          },
          %{
            "id" => "4ae929a7-1973-43f2-a1a8-9221b91a4c0e",
            "name" => "Finance"
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
