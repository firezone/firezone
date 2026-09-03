defmodule PortalAPI.Schemas.Log do
  defmodule Change do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    alias PortalAPI.Schemas

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "ChangeLog",
      description: """
      A single entry from the account audit log.

      Each entry records one create, update, or delete event against an
      account-scoped object.
      """,
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["change"]},
        log_id: %Schema{
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
      example: %{
        "type" => "change",
        "log_id" => "c00060db0c2c8eb400000000",
        "timestamp" => "2026-05-26T12:34:56.789Z",
        "object" => "actors",
        "operation" => "update",
        "before" => %{"name" => "Jane Doe"},
        "after" => %{"name" => "Jane Smith"},
        "subject" => nil
      }
    }))
  end

  defmodule Session do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    alias PortalAPI.Schemas
    alias PortalAPI.Schemas.SessionSubject

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "SessionLog",
      description: """
      A single Session Log entry, recording one Client, Gateway, or Portal
      session that was created, along with the auth context it was created
      with.
      """,
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["session"]},
        log_id: %Schema{
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
        subject: %Schema{
          nullable: true,
          description: """
          Who established the session and from where. The shape depends on
          `context`, which is the field to switch on:

          - `client`: a `ClientSessionSubject` - the actor, plus the Client and
            token the session was established with.
          - `gateway`: a `GatewaySessionSubject` - the Gateway and its token. A
            Gateway authenticates as itself, so no actor fields are recorded.
          - `portal`: a plain `Subject`.
          """,
          oneOf: [SessionSubject.Client, SessionSubject.Gateway, Schemas.Subject]
        }
      },
      example: %{
        "type" => "session",
        "log_id" => "500060db0c2c8eb400000000",
        "timestamp" => "2026-05-26T12:34:56.789Z",
        "context" => "client",
        "subject" => %{
          "actor_id" => "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "actor_name" => "Admin User",
          "actor_email" => "admin@example.com",
          "actor_type" => "account_admin_user",
          "auth_provider_id" => "98776234-1234-5678-9012-345678901234",
          "device_id" => "11e7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "token_id" => "22e7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "ip" => "189.172.73.1",
          "ip_region" => "MX",
          "ip_city" => "Mexico City",
          "ip_lat" => 19.4326,
          "ip_lon" => -99.1332,
          "user_agent" => "Linux/6.5.0 connlib/1.5.1"
        }
      }
    }))
  end

  defmodule Flow do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "FlowLog",
      description: """
      A single Flow Log entry, recording one network flow as accounted by one
      of its two endpoints.

      Both endpoints of a flow report it independently, so a flow yields up to
      two entries that differ only in `role` and in the counters each side
      observed. Every other field is oriented from the initiator regardless of
      which side reported the entry: `inner_src_*` is always the initiator,
      `inner_dst_*` always the responder, and `tx_*` always counts
      initiator-to-responder traffic. `outers` records each outer network path
      in the order it was observed. Comparing the two entries of a flow is how
      reported traffic is cross-checked.
      """,
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["flow"]},
        log_id: %Schema{
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
        initiator_device_id: %Schema{example: "11e7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          description: "ID of the Client that opened the flow. Always a Client."
        },
        responder_device_id: %Schema{example: "9d3a1c40-5f2b-4c8e-9a71-0b6d4e2f8c13",
          type: :string,
          description: """
          ID of the device the flow was opened to: the Gateway serving the
          Resource, or the receiving Client for device-to-device flows.
          """
        },
        role: %Schema{
          type: :string,
          enum: ["initiator", "responder"],
          description: """
          Which of the two endpoints reported this entry: `initiator` means
          `initiator_device_id` wrote it, `responder` means
          `responder_device_id` did. Gateways always report `responder`;
            Clients report either role.
          """
        },
        policy_authorization_id: %Schema{example: "6fa1d58f-0289-42e6-a3ba-7edfa46ee2d5",
          type: :string,
          description: "ID of the Policy Authorization that permitted the flow."
        },
        policy_id: %Schema{example: "46f997d1-77c8-4936-8655-8f050dffbfa4",
          type: :string,
          description: "ID of the Policy that permitted the flow."
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
          nullable: true,
          description: "RFC 3339 timestamp of when the flow ended. Null while the flow is open."
        },
        last_packet: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "When the last packet was seen. Null while the flow is open."
        },
        authorized_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When access to the Resource was authorized."
        },
        authorization_expires_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the Policy Authorization expires."
        },
        initiator_auth_provider_id: %Schema{example: "7b2c1e40-9f3a-4d21-8c5e-1a2b3c4d5e6f",
          type: :string,
          nullable: true,
          description: """
          ID of the Auth Provider the initiating Client authenticated with.
          """
        },
        initiator_actor_id: %Schema{example: "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          nullable: true,
          description: """
          ID of the Actor who opened the flow. This is always the initiating
          Client's Actor. A Gateway has no Actor, and for device-to-device
          flows the receiving Client's own Actor is not recorded here.
          """
        },
        initiator_actor_name: %Schema{example: "John Doe", type: :string, nullable: true},
        initiator_actor_email: %Schema{example: "user@example.com", type: :string, nullable: true},
        initiator_client_version: %Schema{example: "1.5.1",
          type: :string,
          nullable: true,
          description: "Firezone Client version reported by the initiating Client."
        },
        initiator_device_os_name: %Schema{example: "macOS",
          type: :string,
          nullable: true,
          description: "Operating system reported by the initiating Client."
        },
        initiator_device_os_version: %Schema{example: "15.5",
          type: :string,
          nullable: true,
          description: "Operating system version reported by the initiating Client."
        },
        initiator_device_serial: %Schema{example: "C02ABC123",
          type: :string,
          nullable: true,
          description: "Device serial number reported by the initiating Client."
        },
        initiator_device_uuid: %Schema{example: "0C4A8D24-FA9F-4E56-9B57-40D0D46A245E",
          type: :string,
          nullable: true,
          description: "Device UUID reported by the initiating Client."
        },
        initiator_device_identifier_for_vendor: %Schema{example: "C242BC21-AB4A-4F6D-B755-F50E2B5B51B7",
          type: :string,
          nullable: true,
          description: "Vendor identifier reported by the initiating Client."
        },
        initiator_device_firebase_installation_id: %Schema{example: "firebase-installation-id",
          type: :string,
          nullable: true,
          description: "Firebase installation ID reported by the initiating Client."
        },
        resource_id: %Schema{example: "44e7f82f-831a-4a9d-8f17-c66c2bb6e205", type: :string, description: "ID of the Resource accessed."},
        resource_name: %Schema{example: "GitLab", type: :string},
        resource_address: %Schema{example: "gitlab.company.com",
          type: :string,
          nullable: true,
          description: "Resource address, when the Resource type has one."
        },
        inner_src_ip: %Schema{example: "100.64.0.1",
          type: :string,
          description: "Tunnel IP of the initiator, on both entries of the flow."
        },
        inner_dst_ip: %Schema{example: "10.0.0.5",
          type: :string,
          description: "Tunnel IP of the responder, on both entries of the flow."
        },
        inner_src_port: %Schema{type: :integer},
        inner_dst_port: %Schema{type: :integer},
        inner_domain: %Schema{example: "gitlab.company.com",
          type: :string,
          nullable: true,
          description: "Domain name for flows to DNS Resources."
        },
        outers: %Schema{
          type: :array,
          minItems: 1,
          nullable: true,
          description: """
          Outer network paths in observation order. Null while the flow is open;
          the close report replaces it with the complete array. Source IP and
          port must either both be populated or both be absent/null. The two
          entries of a flow can disagree whenever NAT or a relay sits between
          the peers.
          """,
          items: %Schema{
            type: :object,
            properties: %{
              src_ip: %Schema{
                type: :string,
                nullable: true
              },
              src_port: %Schema{
                type: :integer,
                nullable: true
              },
              dst_ip: %Schema{type: :string},
              dst_port: %Schema{type: :integer},
              path_activated_at: %Schema{
                type: :string,
                format: :"date-time",
                nullable: true,
                description: "RFC 3339 timestamp of when the path was selected."
              }
            },
            required: [:dst_ip, :dst_port]
          }
        },
        rx_packets: %Schema{
          type: :integer,
          nullable: true,
          description:
            "Packets sent responder-to-initiator, as counted by the reporting side. Null while the flow is open."
        },
        tx_packets: %Schema{
          type: :integer,
          nullable: true,
          description:
            "Packets sent initiator-to-responder, as counted by the reporting side. Null while the flow is open."
        },
        rx_bytes: %Schema{
          type: :integer,
          nullable: true,
          description:
            "Bytes sent responder-to-initiator, as counted by the reporting side. Null while the flow is open."
        },
        tx_bytes: %Schema{
          type: :integer,
          nullable: true,
          description:
            "Bytes sent initiator-to-responder, as counted by the reporting side. Null while the flow is open."
        }
      }
    }))
  end

  defmodule APIRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "APIRequestLog",
      description: """
      A single API Request Log entry, recording one authenticated REST API
      request.
      """,
      type: :object,
      properties: %{
        type: %Schema{type: :string, enum: ["api_request"]},
        log_id: %Schema{
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
        ip: %Schema{type: :string},
        ip_region: %Schema{type: :string, nullable: true},
        ip_city: %Schema{type: :string, nullable: true},
        ip_lat: %Schema{type: :number, nullable: true},
        ip_lon: %Schema{type: :number, nullable: true}
      },
      example: %{
        "type" => "api_request",
        "log_id" => "a00060db0c2c8eb400000000",
        "timestamp" => "2026-05-26T12:34:56.789Z",
        "actor_id" => "84e7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "api_token_id" => "44e7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "method" => "GET",
        "path" => "/clients",
        "content_length" => nil,
        "request_id" => "GBKkV1jUWuW2sJoAACkB",
        "user_agent" => "curl/8.7.1",
        "ip" => "189.172.73.1",
        "ip_region" => "MX",
        "ip_city" => "Mexico City",
        "ip_lat" => 19.4326,
        "ip_lon" => -99.1332
      }
    }))
  end

  defmodule Item do
    require OpenApiSpex
    alias PortalAPI.Schemas.Log

    OpenApiSpex.schema(%{
      title: "Log",
      description: """
      A single Log entry. The `type` field identifies the log stream the
      entry belongs to, which is also encoded in the first character of its
      `log_id` (`c` change, `5` session, `f` flow, `a` api_request).
      """,
      oneOf: [Log.Change, Log.Session, Log.Flow, Log.APIRequest]
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias PortalAPI.Schemas.Log

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "LogResponse",
      description: "Response schema for a single Log entry.",
      type: :object,
      properties: %{
        data: Log.Item
      }
    }))
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Log

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
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
      }
    }))
  end
end
