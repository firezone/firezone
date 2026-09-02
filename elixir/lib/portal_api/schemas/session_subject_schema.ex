defmodule PortalAPI.Schemas.SessionSubject do
  @moduledoc """
  Subject shapes recorded on Session Log entries.

  A session's subject varies with the `context` it was created in, so
  `SessionLog.subject` is a union of these. Portal sessions record a plain
  `Subject`; the two shapes here differ from it.
  """

  defmodule Client do
    use PortalAPI.Schemas.Object

    object(%{
      title: "ClientSessionSubject",
      description: """
      Subject of a session created by a Client (`context: "client"`).

      A `Subject` plus the Client and token the session was established with.
      """,
      type: :object,
      properties: %{
        actor_id: %Schema{
          type: :string,
          format: :uuid,
          description: "Identifier of the actor that signed in."
        },
        actor_name: %Schema{type: :string, description: "Display name of the actor."},
        actor_email: %Schema{
          type: :string,
          nullable: true,
          description: "Email address of the actor, if any."
        },
        actor_type: %Schema{
          type: :string,
          enum: ["account_user", "account_admin_user", "service_account", "api_client"],
          description: "Type of the actor."
        },
        auth_provider_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Identifier of the authentication provider that authenticated the actor."
        },
        device_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Identifier of the Client the session was established from."
        },
        token_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Identifier of the Client token the session was established with."
        },
        ip: %Schema{type: :string, nullable: true, description: "IP address the session came from."},
        ip_region: %Schema{
          type: :string,
          nullable: true,
          description: "Geo-located region for `ip`, if known."
        },
        ip_city: %Schema{
          type: :string,
          nullable: true,
          description: "Geo-located city for `ip`, if known."
        },
        ip_lat: %Schema{
          type: :number,
          nullable: true,
          description: "Geo-located latitude for `ip`, if known."
        },
        ip_lon: %Schema{
          type: :number,
          nullable: true,
          description: "Geo-located longitude for `ip`, if known."
        },
        user_agent: %Schema{
          type: :string,
          nullable: true,
          description: "User agent reported by the Client."
        }
      }
    })
  end

  defmodule Gateway do
    use PortalAPI.Schemas.Object

    object(%{
      title: "GatewaySessionSubject",
      description: """
      Subject of a session created by a Gateway (`context: "gateway"`).

      A Gateway authenticates with a token rather than as an actor, so no actor
      fields are recorded.
      """,
      type: :object,
      properties: %{
        gateway_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Identifier of the Gateway the session was established from."
        },
        token_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Identifier of the Gateway token the session was established with."
        },
        ip: %Schema{type: :string, nullable: true, description: "IP address the session came from."},
        ip_region: %Schema{
          type: :string,
          nullable: true,
          description: "Geo-located region for `ip`, if known."
        },
        ip_city: %Schema{
          type: :string,
          nullable: true,
          description: "Geo-located city for `ip`, if known."
        },
        ip_lat: %Schema{
          type: :number,
          nullable: true,
          description: "Geo-located latitude for `ip`, if known."
        },
        ip_lon: %Schema{
          type: :number,
          nullable: true,
          description: "Geo-located longitude for `ip`, if known."
        },
        user_agent: %Schema{
          type: :string,
          nullable: true,
          description: "User agent reported by the Gateway."
        }
      }
    })
  end
end
