defmodule PortalAPI.Schemas.Log do
  defmodule Change do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas

    OpenApiSpex.schema(%{
      title: "ChangeLog",
      description: """
      A single entry from the account audit log.

      Each entry records one create, update, or delete event against an
      account-scoped object.
      """,
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["change"]},
        event_id: %Schema{
          type: :string,
          description: """
          Opaque identifier for the audit log entry. A 24-character lowercase
          hexadecimal string starting with `c`, lexicographically sortable
          within an account and aligned with the order changes were committed.
          """,
          example: "c00060db0c2c8eb400000000"
        },
        timestamp: %Schema{
          type: :string,
          format: :"date-time",
          description: "RFC 3339 timestamp identifying when the change was committed."
        },
        object: %Schema{
          type: :string,
          description: "The kind of object that was changed.",
          example: "actors"
        },
        operation: %Schema{
          type: :string,
          enum: ["insert", "update", "delete"],
          description: "The kind of change that was applied."
        },
        before: %Schema{
          type: :object,
          nullable: true,
          description: """
          The state of the object before the change. `null` for `insert`
          events. Sensitive fields such as tokens, secrets, and password
          hashes are replaced with the literal string `"[redacted]"`.
          """,
          additionalProperties: true
        },
        after: %Schema{
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
      required: [:type, :event_id, :timestamp, :object, :operation],
      example: %{
        "type" => "change",
        "event_id" => "c00060db0c2c8eb400000000",
        "timestamp" => "2026-05-26T12:34:56.789Z",
        "object" => "actors",
        "operation" => "update",
        "before" => %{"name" => "Jane Doe"},
        "after" => %{"name" => "Jane Smith"},
        "subject" => nil
      }
    })
  end

  defmodule Session do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SessionLog",
      description: """
      A single Session Log entry, recording one Client, Gateway, or Portal
      session that was created, along with the auth context it was created
      with.
      """,
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["session"]},
        event_id: %Schema{
          type: :string,
          description: """
          Opaque identifier for the Session Log entry. A 24-character
          lowercase hexadecimal string starting with `5`.
          """,
          example: "500060db0c2c8eb400000000"
        },
        timestamp: %Schema{
          type: :string,
          format: :"date-time",
          description: "RFC 3339 timestamp identifying when the session was created."
        },
        context: %Schema{
          type: :string,
          enum: ["client", "gateway", "portal"],
          description: "The kind of session that was created."
        },
        actor_id: %Schema{
          type: :string,
          nullable: true,
          description: "ID of the Actor that created the session."
        },
        actor_email: %Schema{
          type: :string,
          nullable: true,
          description: """
          The Actor's email as recorded when the session was created. `null`
          for Gateway sessions and for Actors without an email.
          """
        },
        device_id: %Schema{
          type: :string,
          nullable: true,
          description:
            "ID of the Client or Gateway that connected. Set for `client` and `gateway` sessions."
        },
        token_id: %Schema{
          type: :string,
          nullable: true,
          description:
            "ID of the Client or Gateway token used. Set for `client` and `gateway` sessions."
        },
        auth_provider_id: %Schema{
          type: :string,
          nullable: true,
          description: "ID of the Auth Provider used to sign in. Set for `portal` sessions."
        },
        user_agent: %Schema{type: :string, nullable: true},
        remote_ip: %Schema{type: :string, nullable: true},
        remote_ip_location_region: %Schema{type: :string, nullable: true},
        remote_ip_location_city: %Schema{type: :string, nullable: true},
        remote_ip_location_lat: %Schema{type: :number, nullable: true},
        remote_ip_location_lon: %Schema{type: :number, nullable: true}
      },
      required: [:type, :event_id, :timestamp, :context],
      example: %{
        "type" => "session",
        "event_id" => "500060db0c2c8eb400000000",
        "timestamp" => "2026-05-26T12:34:56.789Z",
        "context" => "client",
        "actor_id" => nil,
        "actor_email" => nil,
        "device_id" => "11e7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "token_id" => "22e7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "auth_provider_id" => nil,
        "user_agent" => "Linux/6.5.0 connlib/1.5.1",
        "remote_ip" => "189.172.73.1",
        "remote_ip_location_region" => "MX",
        "remote_ip_location_city" => "Mexico City",
        "remote_ip_location_lat" => 19.4326,
        "remote_ip_location_lon" => -99.1332
      }
    })
  end

  defmodule Flow do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "FlowLog",
      description: """
      A single Flow Log entry, recording one completed network flow as
      accounted by the Gateway.
      """,
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["flow"]},
        event_id: %Schema{
          type: :string,
          description: """
          Opaque identifier for the Flow Log entry. A 24-character lowercase
          hexadecimal string starting with `f`.
          """,
          example: "f00060db0c2c8eb400000000"
        },
        timestamp: %Schema{
          type: :string,
          format: :"date-time",
          description: "RFC 3339 timestamp identifying when the flow was ingested."
        },
        device_id: %Schema{
          type: :string,
          description: "ID of the Client or Gateway that reported this side of the flow."
        },
        role: %Schema{
          type: :string,
          enum: ["initiator", "responder"],
          description: """
          Whether the reporting device initiated or responded to the flow.
          Gateways always report `responder`; Clients report either role.
          """
        },
        protocol: %Schema{
          type: :string,
          enum: ["tcp", "udp"],
          description: "Transport protocol of the flow."
        },
        flow_start: %Schema{
          type: :string,
          format: :"date-time",
          description: """
          RFC 3339 timestamp of when the flow began. The `begin`/`end`
          window matches flows whose [`flow_start`, `flow_end`) range
          overlaps it.
          """
        },
        flow_end: %Schema{
          type: :string,
          format: :"date-time",
          description: "RFC 3339 timestamp of when the flow ended."
        },
        last_packet: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the last packet of the flow was seen."
        },
        auth_provider_id: %Schema{
          type: :string,
          nullable: true,
          description: "ID of the Auth Provider the Client authenticated with."
        },
        actor_id: %Schema{type: :string, nullable: true, description: "ID of the Actor."},
        actor_name: %Schema{type: :string, nullable: true},
        actor_email: %Schema{type: :string, nullable: true},
        resource_id: %Schema{type: :string, description: "ID of the Resource accessed."},
        resource_name: %Schema{type: :string},
        resource_address: %Schema{type: :string},
        inner_src_ip: %Schema{
          type: :string,
          description: "Tunnel source IP of the flow."
        },
        inner_dst_ip: %Schema{
          type: :string,
          description: "Tunnel destination IP of the flow."
        },
        inner_src_port: %Schema{type: :integer},
        inner_dst_port: %Schema{type: :integer},
        inner_domain: %Schema{
          type: :string,
          nullable: true,
          description: "Domain name for flows to DNS Resources."
        },
        outer_src_ip: %Schema{
          type: :string,
          description: "Network source IP of the WireGuard packets."
        },
        outer_dst_ip: %Schema{
          type: :string,
          description: "Network destination IP of the WireGuard packets."
        },
        outer_src_port: %Schema{type: :integer},
        outer_dst_port: %Schema{type: :integer},
        rx_packets: %Schema{type: :integer},
        tx_packets: %Schema{type: :integer},
        rx_bytes: %Schema{type: :integer},
        tx_bytes: %Schema{type: :integer}
      },
      required: [
        :type,
        :event_id,
        :timestamp,
        :device_id,
        :role,
        :protocol,
        :flow_start,
        :flow_end,
        :last_packet,
        :resource_id,
        :resource_name,
        :resource_address,
        :inner_src_ip,
        :inner_dst_ip,
        :inner_src_port,
        :inner_dst_port,
        :outer_src_ip,
        :outer_dst_ip,
        :outer_src_port,
        :outer_dst_port,
        :rx_packets,
        :tx_packets,
        :rx_bytes,
        :tx_bytes
      ],
      example: %{
        "type" => "flow",
        "event_id" => "f00060db0c2c8eb400000000",
        "timestamp" => "2026-05-26T12:34:56.789Z",
        "device_id" => "11e7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "role" => "responder",
        "protocol" => "tcp",
        "flow_start" => "2026-05-26T12:30:00.000Z",
        "flow_end" => "2026-05-26T12:34:00.000Z",
        "last_packet" => "2026-05-26T12:33:58.000Z",
        "actor_email" => "user@example.com",
        "resource_id" => "44e7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "resource_name" => "GitLab",
        "resource_address" => "gitlab.company.com",
        "inner_src_ip" => "100.64.0.1",
        "inner_dst_ip" => "10.0.0.5",
        "inner_src_port" => 54_321,
        "inner_dst_port" => 443,
        "outer_src_ip" => "203.0.113.10",
        "outer_dst_ip" => "198.51.100.5",
        "outer_src_port" => 51_820,
        "outer_dst_port" => 51_820,
        "rx_packets" => 100,
        "tx_packets" => 80,
        "rx_bytes" => 102_400,
        "tx_bytes" => 20_480
      }
    })
  end

  defmodule APIRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "APIRequestLog",
      description: """
      A single API Request Log entry, recording one authenticated REST API
      request.
      """,
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["api_request"]},
        event_id: %Schema{
          type: :string,
          description: """
          Opaque identifier for the API Request Log entry. A 24-character
          lowercase hexadecimal string starting with `a`.
          """,
          example: "a00060db0c2c8eb400000000"
        },
        timestamp: %Schema{
          type: :string,
          format: :"date-time",
          description: "RFC 3339 timestamp identifying when the request was received."
        },
        actor_id: %Schema{type: :string, description: "ID of the API Client actor."},
        api_token_id: %Schema{type: :string, description: "ID of the API token used."},
        method: %Schema{type: :string, description: "HTTP request method.", example: "GET"},
        path: %Schema{type: :string, description: "HTTP request path.", example: "/clients"},
        content_length: %Schema{
          type: :integer,
          nullable: true,
          description: "Value of the Content-Length request header, when present."
        },
        request_id: %Schema{
          type: :string,
          description: "Request ID assigned by the server, for correlating with server logs."
        },
        user_agent: %Schema{type: :string, nullable: true},
        remote_ip: %Schema{type: :string},
        remote_ip_location_region: %Schema{type: :string, nullable: true},
        remote_ip_location_city: %Schema{type: :string, nullable: true},
        remote_ip_location_lat: %Schema{type: :number, nullable: true},
        remote_ip_location_lon: %Schema{type: :number, nullable: true}
      },
      required: [
        :type,
        :event_id,
        :timestamp,
        :actor_id,
        :api_token_id,
        :method,
        :path,
        :request_id,
        :remote_ip
      ],
      example: %{
        "type" => "api_request",
        "event_id" => "a00060db0c2c8eb400000000",
        "timestamp" => "2026-05-26T12:34:56.789Z",
        "actor_id" => "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "api_token_id" => "44e7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "method" => "GET",
        "path" => "/clients",
        "content_length" => nil,
        "request_id" => "GBKkV1jUWuW2sJoAACkB",
        "user_agent" => "curl/8.7.1",
        "remote_ip" => "189.172.73.1",
        "remote_ip_location_region" => "MX",
        "remote_ip_location_city" => "Mexico City",
        "remote_ip_location_lat" => 19.4326,
        "remote_ip_location_lon" => -99.1332
      }
    })
  end

  defmodule Item do
    require OpenApiSpex
    alias PortalAPI.Schemas.Log

    OpenApiSpex.schema(%{
      title: "Log",
      description: """
      A single Log entry. The `type` field identifies the log stream the
      entry belongs to, which is also encoded in the first character of its
      `event_id` (`c` change, `5` session, `f` flow, `a` api_request).
      """,
      oneOf: [Log.Change, Log.Session, Log.Flow, Log.APIRequest]
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias PortalAPI.Schemas.Log

    OpenApiSpex.schema(%{
      title: "LogResponse",
      description: "Response schema for a single Log entry.",
      type: :object,
      properties: %{
        data: Log.Item
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Log

    OpenApiSpex.schema(%{
      title: "LogsResponse",
      description: """
      Response schema for a page of Log entries.

      Entries are returned most recent first. Each page contains at most 100
      entries (50 by default); use the `metadata.next_page` cursor to fetch
      the following page.
      """,
      type: :object,
      properties: %{
        data: %Schema{
          description: "Log entries for the requested window.",
          type: :array,
          items: Log.Item
        },
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "type" => "change",
            "event_id" => "c00060db0c2c8eb400000000",
            "timestamp" => "2026-05-26T12:34:56.789Z",
            "object" => "actors",
            "operation" => "update",
            "before" => %{"name" => "Jane Doe"},
            "after" => %{"name" => "Jane Smith"},
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
