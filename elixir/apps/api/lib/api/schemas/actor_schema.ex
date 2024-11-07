defmodule API.Schemas.Actor do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Actor",
      description: "Actor",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Actor ID"},
        name: %Schema{
          type: :string,
          description: "Actor Name",
          pattern: ~r/[a-zA-Z][a-zA-Z0-9_]+/
        },
        type: %Schema{type: :string, description: "Actor Type"}
      },
      required: [:name, :type],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "John Doe",
        "type" => "account_admin_user"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Actor

    OpenApiSpex.schema(%{
      title: "ActorRequest",
      description: "POST body for creating an Actor",
      type: :object,
      properties: %{
        actor: Actor.Schema
      },
      required: [:actor],
      example: %{
        "actor" => %{
          "name" => "Joe User",
          "type" => "account_admin_user"
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Actor

    OpenApiSpex.schema(%{
      title: "ActorResponse",
      description: "Response schema for single Actor",
      type: :object,
      properties: %{
        data: Actor.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "John Doe",
          "type" => "account_admin_user"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias API.Schemas.Actor

    OpenApiSpex.schema(%{
      title: "ActorsResponse",
      description: "Response schema for multiple Actors",
      type: :object,
      properties: %{
        data: %Schema{description: "Actors details", type: :array, items: Actor.Schema},
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "John Doe",
            "type" => "account_admin_user"
          },
          %{
            "id" => "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "Jane Smith",
            "type" => "account_user"
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
