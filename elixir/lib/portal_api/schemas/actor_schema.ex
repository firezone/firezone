defmodule PortalAPI.Schemas.Actor do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "Actor",
      description: "Actor",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Actor ID"},
        name: %Schema{
          type: :string,
          description: "Actor Name",
          pattern: "[a-zA-Z][a-zA-Z0-9_]+"
        },
        type: %Schema{type: :string, description: "Actor Type"},
        email: %Schema{type: :string, description: "Actor Email", nullable: true},
        allow_email_otp_sign_in: %Schema{
          type: :boolean,
          description: "Allow Email OTP Sign In",
          default: false
        },
        is_disabled: %Schema{
          type: :boolean,
          description: "Whether the actor is disabled",
          default: false
        },
        last_seen_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Last time the actor was seen",
          nullable: true
        },
        created_by_directory_id: %Schema{
          type: :string,
          format: :uuid,
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
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "John Doe",
        "type" => "account_admin_user",
        "email" => "john.doe@example.com",
        "allow_email_otp_sign_in" => false,
        "is_disabled" => false,
        "last_seen_at" => "2024-01-15T10:30:00Z",
        "created_by_directory_id" => nil,
        "inserted_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-15T10:30:00Z"
      }
    })
  end

  defmodule CreateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ActorCreateRequest",
      description: "POST body for creating an Actor",
      type: :object,
      properties: %{
        actor: %Schema{
          type: :object,
          properties: %{
            name: %Schema{
              type: :string,
              description: "Actor Name",
              pattern: "[a-zA-Z][a-zA-Z0-9_]+"
            },
            type: %Schema{
              type: :string,
              description: "Actor Type",
              enum: ["account_user", "account_admin_user", "service_account"]
            },
            email: %Schema{
              type: :string,
              description: "Actor Email. Optional for service accounts.",
              nullable: true
            },
            allow_email_otp_sign_in: %Schema{
              type: :boolean,
              description: "Allow Email OTP Sign In",
              default: false
            }
          },
          required: [:name, :type]
        }
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

  defmodule UpdateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ActorUpdateRequest",
      description:
        "PATCH/PUT body for updating an Actor. All fields are optional; omitted fields keep " <>
          "their current value.",
      type: :object,
      properties: %{
        actor: %Schema{
          type: :object,
          properties: %{
            name: %Schema{
              type: :string,
              description: "Actor Name",
              pattern: "[a-zA-Z][a-zA-Z0-9_]+"
            },
            type: %Schema{
              type: :string,
              description: "Actor Type",
              enum: ["account_user", "account_admin_user", "service_account"]
            },
            email: %Schema{
              type: :string,
              description: "Actor Email. Optional for service accounts.",
              nullable: true
            },
            allow_email_otp_sign_in: %Schema{
              type: :boolean,
              description: "Allow Email OTP Sign In",
              default: false
            },
            is_disabled: %Schema{
              type: :boolean,
              description:
                "Whether the Actor is disabled. Setting this to `true` immediately revokes " <>
                  "the Actor's active Client tokens and portal sessions. An Actor cannot " <>
                  "disable itself.",
              default: false
            }
          }
        }
      },
      required: [:actor],
      example: %{
        "actor" => %{
          "name" => "Joe User",
          "type" => "account_admin_user",
          "email" => "joe.user@example.com",
          "allow_email_otp_sign_in" => false,
          "is_disabled" => false
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
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Actor
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "ActorsResponse",
      description: "Response schema for multiple Actors",
      type: :object,
      properties: %{
        data: %Schema{description: "Actors details", type: :array, items: Actor.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
