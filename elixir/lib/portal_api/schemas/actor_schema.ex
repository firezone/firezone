defmodule PortalAPI.Schemas.Actor do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.Actor, internal: [:account_id, :identity_count, :preferences]}
    OpenApiSpex.schema(%{
      title: "Actor",
      description: "Actor",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Actor ID"
        },
        name: %Schema{
          example: "John Doe",
          type: :string,
          description: "Actor Name"
        },
        type: %Schema{
          example: "account_admin_user",
          type: :string,
          description: "Actor Type",
          enum: ["account_admin_user", "account_user", "api_client", "service_account"]
        },
        email: %Schema{
          example: "john.doe@example.com",
          type: :string,
          description: "Actor Email",
          nullable: true
        },
        allow_email_otp_sign_in: %Schema{
          example: false,
          type: :boolean,
          description: "Allow Email OTP Sign In",
          default: false
        },
        is_disabled: %Schema{
          example: false,
          type: :boolean,
          description: "Whether the actor is disabled",
          default: false
        },
        last_seen_at: %Schema{
          example: "2024-01-15T10:30:00Z",
          type: :string,
          format: :"date-time",
          description: "Last time the actor was seen",
          nullable: true
        },
        created_by_directory_id: %Schema{
          example: nil,
          type: :string,
          format: :uuid,
          description: "Directory ID that created this actor",
          nullable: true
        },
        inserted_at: %Schema{
          example: "2024-01-01T00:00:00Z",
          type: :string,
          format: :"date-time",
          description: "When the actor was created"
        },
        updated_at: %Schema{
          example: "2024-01-15T10:30:00Z",
          type: :string,
          format: :"date-time",
          description: "When the actor was last updated"
        }
      },
      required: [
        :allow_email_otp_sign_in,
        :created_by_directory_id,
        :email,
        :id,
        :inserted_at,
        :is_disabled,
        :last_seen_at,
        :name,
        :type,
        :updated_at
      ]
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
              example: "Joe User",
              type: :string,
              description: "Actor Name"
            },
            type: %Schema{
              example: "account_admin_user",
              type: :string,
              description: "Actor Type",
              enum: ["account_user", "account_admin_user", "service_account"]
            },
            email: %Schema{
              example: "joe.user@example.com",
              type: :string,
              description: "Actor Email. Optional for service accounts.",
              nullable: true
            },
            allow_email_otp_sign_in: %Schema{
              example: false,
              type: :boolean,
              description: "Allow Email OTP Sign In",
              default: false
            }
          },
          required: [:name, :type]
        }
      },
      required: [:actor]
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
              example: "Joe User",
              type: :string,
              description: "Actor Name"
            },
            type: %Schema{
              example: "account_admin_user",
              type: :string,
              description: "Actor Type",
              enum: ["account_user", "account_admin_user", "service_account"]
            },
            email: %Schema{
              example: "joe.user@example.com",
              type: :string,
              description: "Actor Email. Optional for service accounts.",
              nullable: true
            },
            allow_email_otp_sign_in: %Schema{
              example: false,
              type: :boolean,
              description: "Allow Email OTP Sign In",
              default: false
            },
            is_disabled: %Schema{
              example: false,
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
      required: [:actor]
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
