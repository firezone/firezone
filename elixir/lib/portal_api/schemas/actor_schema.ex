defmodule PortalAPI.Schemas.Actor do
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
        type: %Schema{type: :string, description: "Actor Type"},
        email: %Schema{type: :string, description: "Actor Email"},
        allow_email_otp_sign_in: %Schema{
          type: :boolean,
          description: "Allow Email OTP Sign In",
          default: false
        },
        disabled_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the actor was disabled",
          nullable: true
        },
        last_seen_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Last time the actor was seen",
          nullable: true
        },
        created_by_directory_id: %Schema{
          type: :string,
          description: "Directory ID that created this actor",
          nullable: true
        },
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the actor was created"
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the actor was last updated"
        }
      },
      required: [:name, :email, :type],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "John Doe",
        "type" => "account_admin_user",
        "email" => "john.doe@example.com",
        "allow_email_otp_sign_in" => false,
        "disabled_at" => nil,
        "last_seen_at" => "2024-01-15T10:30:00Z",
        "created_by_directory_id" => nil,
        "inserted_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-15T10:30:00Z"
      }
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Actor

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
          "type" => "account_admin_user",
          "email" => "joe.user@example.com",
          "allow_email_otp_sign_in" => false
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Actor

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
          "type" => "account_admin_user",
          "email" => "john.doe@example.com",
          "allow_email_otp_sign_in" => false,
          "disabled_at" => nil,
          "last_seen_at" => "2024-01-15T10:30:00Z",
          "created_by_directory_id" => nil,
          "inserted_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-15T10:30:00Z"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Actor

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
            "type" => "account_admin_user",
            "email" => "john.doe@example.com",
            "allow_email_otp_sign_in" => false,
            "disabled_at" => nil,
            "last_seen_at" => "2024-01-15T10:30:00Z",
            "created_by_directory_id" => nil,
            "inserted_at" => "2024-01-01T00:00:00Z",
            "updated_at" => "2024-01-15T10:30:00Z"
          },
          %{
            "id" => "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "Jane Smith",
            "type" => "account_user",
            "email" => "jane.smith@example.com",
            "allow_email_otp_sign_in" => true,
            "disabled_at" => nil,
            "last_seen_at" => "2024-01-14T15:45:00Z",
            "created_by_directory_id" => "98776234-1234-5678-9012-345678901234",
            "inserted_at" => "2024-01-02T00:00:00Z",
            "updated_at" => "2024-01-14T15:45:00Z"
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
