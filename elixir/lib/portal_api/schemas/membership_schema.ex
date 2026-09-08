defmodule PortalAPI.Schemas.Membership do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.Actor,
             internal: [
               :account_id,
               :allow_email_otp_sign_in,
               :created_by_directory_id,
               :email,
               :identity_count,
               :inserted_at,
               :is_disabled,
               :last_seen_at,
               :preferences,
               :updated_at
             ]}
    OpenApiSpex.schema(%{
      title: "Membership",
      description: "Membership",
      type: :object,
      properties: %{
        id: %Schema{
          example: "7cb89288-1fb3-433e-a522-2d087e45988d",
          type: :string,
          format: :uuid,
          description: "Actor ID"
        },
        name: %Schema{example: "John Doe", type: :string, description: "Actor Name"},
        type: %Schema{
          example: "account_user",
          type: :string,
          description: "Actor Type",
          enum: ["account_admin_user", "account_user", "api_client", "service_account"]
        }
      },
      required: [:id, :name, :type]
    })
  end

  defmodule PatchRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MembershipPatchRequest",
      description: "PATCH body for updating Memberships",
      type: :object,
      properties: %{
        memberships: %Schema{
          type: :object,
          properties: %{
            add: %Schema{
              example: ["4ddfa557-7dfc-484f-894c-2024ec3fe9f7"],
              type: :array,
              description: "Array of Actor IDs",
              items: %Schema{type: :string, format: :uuid, description: "Actor ID"}
            },
            remove: %Schema{
              example: ["89d22f71-939d-442d-b148-897b730adfb4"],
              type: :array,
              description: "Array of Actor IDs",
              items: %Schema{type: :string, format: :uuid, description: "Actor ID"}
            }
          }
        }
      },
      required: [:memberships]
    })
  end

  defmodule PutRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MembershipPutRequest",
      description: "PUT body for updating Memberships",
      type: :object,
      properties: %{
        memberships: %Schema{
          example: [
            %{"actor_id" => "4ddfa557-7dfc-484f-894c-2024ec3fe9f7"},
            %{"actor_id" => "89d22f71-939d-442d-b148-897b730adfb4"}
          ],
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              actor_id: %Schema{type: :string, format: :uuid, description: "Actor ID"}
            }
          }
        }
      },
      required: [:memberships]
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Membership
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "MembershipListResponse",
      description: "Response schema for Memberships",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Membership details",
          type: :array,
          items: Membership.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end

  defmodule MembershipResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "MembershipResponse",
      description: "Response schema for Membership Updates",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          description: "Memberships",
          properties: %{
            actor_ids: %Schema{
              example: [
                "4ddfa557-7dfc-484f-894c-2024ec3fe9f7",
                "89d22f71-939d-442d-b148-897b730adfb4"
              ],
              description: "Actor IDs",
              type: :array,
              items: %Schema{type: :string, format: :uuid, description: "Actor ID"}
            }
          }
        }
      }
    })
  end
end
