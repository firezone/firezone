defmodule PortalAPI.Schemas.FlowLogIngest do
  defmodule Record do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @port %Schema{type: :integer, minimum: 0, maximum: 65_535}
    @counter %Schema{type: :integer, minimum: 0, maximum: 9_223_372_036_854_775_807}
    @close_only_fields [:flow_end, :last_packet, :rx_packets, :tx_packets, :rx_bytes, :tx_bytes]
    @close_fields [:outers | @close_only_fields]
    @any_close_only_field Enum.map(@close_only_fields, &%Schema{required: [&1]})

    @outer %Schema{
      type: :object,
      additionalProperties: false,
      required: [:dst_ip, :dst_port, :path_activated_at],
      properties: %{
        src_ip: %Schema{
          type: :string,
          description: "Absent together with src_port when the source is unknown."
        },
        src_port: @port,
        dst_ip: %Schema{type: :string},
        dst_port: @port,
        path_activated_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Time of the packet that revealed the path."
        }
      },
      oneOf: [
        %Schema{required: [:src_ip, :src_port]},
        %Schema{
          not: %Schema{
            anyOf: [%Schema{required: [:src_ip]}, %Schema{required: [:src_port]}]
          }
        }
      ]
    }

    OpenApiSpex.schema(%{
      title: "FlowLogIngestRecord",
      description: """
      One flow-log record reported by connlib. Attribution is supplied by the
      request's ingest token rather than by each record.
      """,
      type: :object,
      additionalProperties: false,
      required: [
        :protocol,
        :inner_src_ip,
        :inner_src_port,
        :inner_dst_ip,
        :inner_dst_port,
        :flow_start
      ],
      properties: %{
        protocol: %Schema{type: :string, enum: ["tcp", "udp"]},
        inner_src_ip: %Schema{
          type: :string,
          description: "Tunnel IP of the initiator, on both sides' reports."
        },
        inner_src_port: @port,
        inner_dst_ip: %Schema{
          type: :string,
          description: "Tunnel IP of the responder, on both sides' reports."
        },
        inner_dst_port: @port,
        domain: %Schema{
          type: :string,
          description: "Domain name for flows to DNS Resources; absent otherwise."
        },
        outers: %Schema{
          type: :array,
          minItems: 1,
          description: "Ordered outer transport paths accumulated over the flow's lifetime.",
          items: @outer
        },
        flow_start: %Schema{type: :string, format: :"date-time"},
        flow_end: %Schema{
          type: :string,
          format: :"date-time",
          description: "Absent on the open report."
        },
        last_packet: %Schema{type: :string, format: :"date-time"},
        rx_packets: @counter,
        tx_packets: @counter,
        rx_bytes: @counter,
        tx_bytes: @counter
      },
      oneOf: [
        %Schema{
          description: "An open report may include paths known so far, but omits its end time and counters.",
          not: %Schema{anyOf: @any_close_only_field}
        },
        %Schema{
          description: "A close report includes outer paths, its end time, and all counters.",
          required: @close_fields
        }
      ]
    })
  end

  defmodule Request do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "FlowLogIngestRequest",
      description: "A batch of flow-log records for one policy authorization.",
      type: :object,
      additionalProperties: false,
      required: [:flow_logs],
      properties: %{
        flow_logs: %Schema{type: :array, maxItems: 10_000, items: Record}
      }
    })
  end
end
