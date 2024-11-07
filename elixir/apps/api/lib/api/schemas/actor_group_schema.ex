defmodule API.Schemas.ActorGroup do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ActorGroup",
      description: "Actor Group",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Actor Group ID"},
        name: %Schema{type: :string, description: "Actor Group Name"}
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
    alias API.Schemas.ActorGroup

    OpenApiSpex.schema(%{
      title: "ActorGroupRequest",
      description: "POST body for creating an Actor Group",
      type: :object,
      properties: %{
        actor_group: ActorGroup.Schema
      },
      required: [:actor_group],
      example: %{
        "actor_group" => %{
          "name" => "Engineering"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.ActorGroup

    OpenApiSpex.schema(%{
      title: "ActorGroupResponse",
      description: "Response schema for single Actor Group",
      type: :object,
      properties: %{
        data: ActorGroup.Schema
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
    alias API.Schemas.ActorGroup

    OpenApiSpex.schema(%{
      title: "ActorGroupListResponse",
      description: "Response schema for multiple Actor Groups",
      type: :object,
      properties: %{
        data: %Schema{description: "Actor Group details", type: :array, items: ActorGroup.Schema},
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
