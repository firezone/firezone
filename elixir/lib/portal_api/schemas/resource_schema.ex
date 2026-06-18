defmodule PortalAPI.Schemas.Resource do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "Resource",
      description: "Resource",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Resource ID"},
        name: %Schema{type: :string, description: "Resource name"},
        address: %Schema{type: :string, description: "Resource address"},
        address_description: %Schema{type: :string, description: "Resource address description"},
        type: %Schema{
          type: :string,
          description: "Resource type. For `static_device_pool`, `address` is not applicable.",
          enum: ["cidr", "ip", "dns", "static_device_pool"]
        },
        ip_stack: %Schema{
          type: :string,
          description: "IP stack type. Only supported for DNS resources.",
          enum: ["ipv4_only", "ipv6_only", "dual"]
        },
        site_id: %Schema{
          title: "SiteID",
          description:
            "Site to connect the Resource to. Required for all types except `static_device_pool`.",
          type: :string,
          format: :uuid
        },
        filters: %Schema{
          type: :array,
          description:
            "Traffic filters restricting the protocols and ports the Resource exposes",
          items: PortalAPI.Schemas.Resource.Filter
        }
      },
      required: [:name, :type],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Prod DB",
        "address" => "10.0.0.10",
        "address_description" => "Production Database",
        "type" => "ip",
        "filters" => [
          %{"protocol" => "tcp", "ports" => ["5432"]}
        ]
      }
    })
  end

  defmodule Filter do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "ResourceFilter",
      description: "Traffic filter restricting the protocols and ports the Resource exposes",
      type: :object,
      properties: %{
        protocol: %Schema{
          type: :string,
          description: "Transport protocol the filter applies to",
          enum: ["tcp", "udp", "icmp"]
        },
        ports: %Schema{
          type: :array,
          description:
            "Port numbers or ranges (e.g. `80` or `8000 - 9000`) the filter allows. " <>
              "Not applicable to `icmp`.",
          items: %Schema{type: :string}
        }
      },
      required: [:protocol],
      example: %{
        "protocol" => "tcp",
        "ports" => ["80", "443", "8000 - 9000"]
      }
    })
  end

  defmodule CreateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Resource

    OpenApiSpex.schema(%{
      title: "ResourceCreateRequest",
      description:
        "POST body for creating a Resource. `site_id` is required unless `type` is " <>
          "`static_device_pool`.",
      type: :object,
      properties: %{
        resource: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Resource name"},
            address: %Schema{
              type: :string,
              description: "Resource address. Not applicable to `static_device_pool`.",
              nullable: true
            },
            address_description: %Schema{
              type: :string,
              description: "Resource address description",
              nullable: true
            },
            type: %Schema{
              type: :string,
              description: "Resource type. For `static_device_pool`, `address` is not applicable.",
              enum: ["cidr", "ip", "dns", "static_device_pool"]
            },
            ip_stack: %Schema{
              type: :string,
              description: "IP stack type. Only supported for DNS resources.",
              enum: ["ipv4_only", "ipv6_only", "dual"],
              nullable: true
            },
            site_id: %Schema{
              title: "SiteID",
              description:
                "Site to connect the Resource to. Required for all types except `static_device_pool`.",
              type: :string,
              format: :uuid,
              nullable: true
            },
            filters: %Schema{
              type: :array,
              description:
                "Traffic filters restricting the protocols and ports the Resource exposes",
              items: Resource.Filter
            }
          },
          required: [:name, :type]
        }
      },
      required: [:resource],
      example: %{
        "resource" => %{
          "name" => "Prod DB",
          "address" => "10.0.0.10",
          "address_description" => "Production Database",
          "type" => "ip",
          "site_id" => "0642e09d-b3a2-47e4-9cd1-c2195faeeb67",
          "filters" => [
            %{"protocol" => "tcp", "ports" => ["5432"]}
          ]
        }
      }
    })
  end

  defmodule UpdateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Resource

    OpenApiSpex.schema(%{
      title: "ResourceUpdateRequest",
      description:
        "PATCH/PUT body for updating a Resource. All fields are optional; omitted fields keep " <>
          "their current value.",
      type: :object,
      properties: %{
        resource: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Resource name"},
            address: %Schema{
              type: :string,
              description: "Resource address. Not applicable to `static_device_pool`.",
              nullable: true
            },
            address_description: %Schema{
              type: :string,
              description: "Resource address description",
              nullable: true
            },
            type: %Schema{
              type: :string,
              description: "Resource type. For `static_device_pool`, `address` is not applicable.",
              enum: ["cidr", "ip", "dns", "static_device_pool"]
            },
            ip_stack: %Schema{
              type: :string,
              description: "IP stack type. Only supported for DNS resources.",
              enum: ["ipv4_only", "ipv6_only", "dual"],
              nullable: true
            },
            site_id: %Schema{
              title: "SiteID",
              description:
                "Site to connect the Resource to. Required for all types except `static_device_pool`.",
              type: :string,
              format: :uuid,
              nullable: true
            },
            filters: %Schema{
              type: :array,
              description:
                "Traffic filters restricting the protocols and ports the Resource exposes",
              items: Resource.Filter
            }
          }
        }
      },
      required: [:resource],
      example: %{
        "resource" => %{
          "name" => "Prod DB",
          "address" => "10.0.0.10",
          "address_description" => "Production Database",
          "type" => "ip",
          "site_id" => "0642e09d-b3a2-47e4-9cd1-c2195faeeb67",
          "filters" => [
            %{"protocol" => "tcp", "ports" => ["5432"]}
          ]
        }
      }
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Resource

    OpenApiSpex.schema(%{
      title: "ResourceResponse",
      description: "Response schema for single Resource",
      type: :object,
      properties: %{
        data: Resource.Schema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "name" => "Prod DB",
          "address" => "10.0.0.10",
          "address_description" => "Production Database",
          "type" => "ip"
        }
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Resource

    OpenApiSpex.schema(%{
      title: "ResourceListResponse",
      description: "Response schema for multiple Resources",
      type: :object,
      properties: %{
        data: %Schema{description: "Resource details", type: :array, items: Resource.Schema},
        metadata: %Schema{description: "Pagination metadata", type: :object}
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "name" => "Prod DB",
            "address" => "10.0.0.10",
            "address_description" => "Production Database",
            "type" => "ip"
          },
          %{
            "id" => "3b9451c9-5616-48f8-827f-009ace22d015",
            "name" => "Admin Dashboard",
            "address" => "10.0.0.20",
            "address_description" => "Production Admin Dashboard",
            "type" => "ip"
          }
        ],
        "metadata" => %{
          "limit" => 10,
          "total" => 100,
          "prev_page" => "123123425",
          "next_page" => "98776234123"
        }
      }
    })
  end
end
