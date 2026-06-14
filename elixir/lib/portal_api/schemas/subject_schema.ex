defmodule PortalAPI.Schemas.Subject do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Subject",
    description: """
    Identifies the actor and request context that initiated an action.

    Used to describe the principal behind an audit log entry, an authorized
    flow, or any other event surfaced through the API. May be `null` when
    the action originated outside the context of a Firezone session.
    """,
    type: :object,
    nullable: true,
    properties: %{
      actor_id: %Schema{
        type: :string,
        format: :uuid,
        description: "Identifier of the actor that initiated the action."
      },
      actor_name: %Schema{
        type: :string,
        description: "Display name of the actor."
      },
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
      ip: %Schema{
        type: :string,
        nullable: true,
        description: "IP address the action originated from."
      },
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
        description: "User agent of the client that initiated the action."
      }
    },
    example: %{
      "actor_id" => "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
      "actor_name" => "Admin User",
      "actor_email" => "admin@example.com",
      "actor_type" => "account_admin_user",
      "auth_provider_id" => "98776234-1234-5678-9012-345678901234",
      "ip" => "1.2.3.4",
      "ip_region" => "California",
      "ip_city" => "San Francisco",
      "ip_lat" => 37.7749,
      "ip_lon" => -122.4194,
      "user_agent" => "Mozilla/5.0"
    }
  })
end
