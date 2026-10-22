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
      attested_device_serial: %Schema{
        type: :string,
        description: "Device serial from the device's last attestation. Omitted when absent."
      },
      attested_device_uuid: %Schema{
        type: :string,
        description: "Device UUID from the device's last attestation. Omitted when absent."
      },
      attested_mdm_device_id: %Schema{
        type: :string,
        description: "MDM device ID from the device's last attestation. Omitted when absent."
      },
      attested_cert_serial: %Schema{
        type: :string,
        description: "Certificate serial from the device's last attestation. Omitted when absent."
      },
      attested_cert_fingerprint: %Schema{
        type: :string,
        description: "Certificate fingerprint from the device's last attestation. Omitted when absent."
      },
      attested_cert_issuer: %Schema{
        type: :string,
        format: :byte,
        description: "Base64-encoded DER X.509 issuer Name from the device's last attestation. Omitted when absent."
      },
      attested_at: %Schema{
        type: :string,
        format: :"date-time",
        description: "When the device last attested, snapshotted for this subject. Does not imply the current connection attested. Omitted when absent."
      },
      actor_id: %Schema{
        example: "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
        type: :string,
        format: :uuid,
        description: "Identifier of the actor that initiated the action."
      },
      actor_name: %Schema{
        example: "Admin User",
        type: :string,
        description: "Display name of the actor."
      },
      actor_email: %Schema{
        example: "admin@example.com",
        type: :string,
        nullable: true,
        description: "Email address of the actor, if any."
      },
      actor_type: %Schema{
        example: "account_admin_user",
        type: :string,
        enum: ["account_user", "account_admin_user", "service_account", "api_client"],
        description: "Type of the actor."
      },
      auth_provider_id: %Schema{
        example: "98776234-1234-5678-9012-345678901234",
        type: :string,
        format: :uuid,
        nullable: true,
        description: "Identifier of the authentication provider that authenticated the actor."
      },
      ip: %Schema{
        example: "1.2.3.4",
        type: :string,
        nullable: true,
        description: "IP address the action originated from."
      },
      ip_region: %Schema{
        example: "California",
        type: :string,
        nullable: true,
        description: "Geo-located region for `ip`, if known."
      },
      ip_city: %Schema{
        example: "San Francisco",
        type: :string,
        nullable: true,
        description: "Geo-located city for `ip`, if known."
      },
      ip_lat: %Schema{
        example: 37.7749,
        type: :number,
        nullable: true,
        description: "Geo-located latitude for `ip`, if known."
      },
      ip_lon: %Schema{
        example: -122.4194,
        type: :number,
        nullable: true,
        description: "Geo-located longitude for `ip`, if known."
      },
      user_agent: %Schema{
        example: "Mozilla/5.0",
        type: :string,
        nullable: true,
        description: "User agent of the client that initiated the action."
      }
    }
  })
end
