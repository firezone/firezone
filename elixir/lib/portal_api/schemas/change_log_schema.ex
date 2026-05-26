defmodule PortalAPI.Schemas.ChangeLog do
  defmodule GetSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas

    OpenApiSpex.schema(%{
      title: "ChangeLog",
      description: """
      A single entry from the account audit log.

      Each entry records one create, update, or delete event against an
      account-scoped object. Entries are returned in time-based order with
      the most recent change first.
      """,
      type: :object,
      properties: %{
        id: %Schema{
          type: :string,
          description: """
          Opaque identifier for the audit log entry. Lexicographically sortable
          within an account and aligned with the order changes were committed.
          """,
          example: "c00060db0c2c8eb400000000"
        },
        timestamp: %Schema{
          type: :string,
          format: :"date-time",
          description: "RFC 3339 timestamp identifying when the change was committed."
        },
        kind: %Schema{
          type: :string,
          description: "The kind of object that was changed.",
          example: "actors"
        },
        op: %Schema{
          type: :string,
          enum: ["insert", "update", "delete"],
          description: "The kind of change that was applied."
        },
        old_data: %Schema{
          type: :object,
          nullable: true,
          description: """
          The state of the object before the change. `null` for `insert`
          events. Sensitive fields such as tokens, secrets, and password
          hashes are replaced with the literal string `"[redacted]"`.
          """,
          additionalProperties: true
        },
        data: %Schema{
          type: :object,
          nullable: true,
          description: """
          The state of the object after the change. `null` for `delete`
          events. Sensitive fields such as tokens, secrets, and password
          hashes are replaced with the literal string `"[redacted]"`.
          """,
          additionalProperties: true
        },
        subject: Schemas.Subject
      },
      required: [:id, :timestamp, :kind, :op],
      example: %{
        "id" => "c00060db0c2c8eb400000000",
        "timestamp" => "2026-05-26T12:34:56.789Z",
        "kind" => "actors",
        "op" => "update",
        "old_data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "Jane Doe",
          "email" => "jane@example.com"
        },
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "Jane Smith",
          "email" => "jane.smith@example.com"
        },
        "subject" => %{
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
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias PortalAPI.Schemas.ChangeLog

    OpenApiSpex.schema(%{
      title: "ChangeLogResponse",
      description: "Response schema for a single Change Log entry.",
      type: :object,
      properties: %{
        data: ChangeLog.GetSchema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.ChangeLog

    OpenApiSpex.schema(%{
      title: "ChangeLogsResponse",
      description: """
      Response schema for a page of Change Log entries.

      Entries are returned in `event_id` order with the most recent change
      first. Use the `metadata.next_page` cursor to fetch the following page.
      """,
      type: :object,
      properties: %{
        data: %Schema{
          description: "Change log entries for the requested window.",
          type: :array,
          items: ChangeLog.GetSchema
        },
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "c00060db0c2c8eb400000000",
            "timestamp" => "2026-05-26T12:34:56.789Z",
            "kind" => "actors",
            "op" => "update",
            "old_data" => %{"name" => "Jane Doe"},
            "data" => %{"name" => "Jane Smith"},
            "subject" => nil
          }
        ],
        "metadata" => %{
          "count" => 1,
          "limit" => 50,
          "next_page" => nil,
          "prev_page" => nil
        }
      }
    })
  end
end
