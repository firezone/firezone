defmodule PortalAPI.Schemas.Resource do
  alias OpenApiSpex.Schema
  require Protocol

  # ip_stack and site_id are omitted rather than null when unset.
  Protocol.derive(PortalAPI.JSON.Encoder, Portal.Resource,
    except: [:account_id, :inserted_at, :updated_at, :ip_stack, :site_id],
    mapper: &PortalAPI.Schemas.Resource.map/2
  )

  def map(%Portal.Resource{} = resource, _map) do
    %{filters: Enum.map(resource.filters, &%{protocol: &1.protocol, ports: &1.ports})}
    |> put_present(:ip_stack, resource.ip_stack)
    |> put_present(:site_id, resource.site_id)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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
        address: %Schema{
          type: :string,
          nullable: true,
          description: "Resource address. Null for `static_device_pool` Resources."
        },
        address_description: %Schema{
          type: :string,
          nullable: true,
          description: "Resource address description"
        },
        type: %Schema{
          type: :string,
          description:
            "Resource type. For `static_device_pool` and `dynamic_device_pool`, `address` " <>
              "is not applicable. Only `cidr`, `ip`, and `dns` Resources can be created " <>
              "through the API.",
          enum: ["cidr", "ip", "dns", "internet", "static_device_pool", "dynamic_device_pool"]
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
          description: "Traffic filters restricting the protocols and ports the Resource exposes",
          items: PortalAPI.Schemas.Resource.Filter
        }
      },
      required: [:address, :address_description, :filters, :id, :name, :type],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "name" => "Prod DB",
        "address" => "10.0.0.10",
        "address_description" => "Production Database",
        "type" => "ip",
        "filters" => [
          %{"protocol" => "tcp", "ports" => ["5432"]}
        ],
        "site_id" => "0642e09d-b3a2-47e4-9cd1-c2195faeeb67"
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
        "POST body for creating a Resource. `site_id` is required.\n\n" <>
          "Device pools (`static_device_pool`) cannot currently be created through this " <>
          "API - create them in the admin portal. Existing pools can be read, updated, " <>
          "deleted, and have their members managed here as normal.",
      type: :object,
      properties: %{
        resource: %Schema{
          type: :object,
          properties: %{
            name: %Schema{type: :string, description: "Resource name"},
            address: %Schema{
              type: :string,
              description: "Resource address.",
              nullable: true
            },
            address_description: %Schema{
              type: :string,
              description: "Resource address description",
              nullable: true
            },
            type: %Schema{
              type: :string,
              # static_device_pool is deliberately absent: pools cannot be
              # created or converted to through this API for now. It stays
              # in the response schema below, since existing pools are
              # still returned. See
              # PortalAPI.ResourceController.Database.reject_device_pool_type/1
              # for what to change to re-enable it.
              description: "Resource type. `internet` is accepted only in the Internet Site.",
              enum: ["cidr", "ip", "dns", "internet"]
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
                "Site to connect the Resource to. Required. " <>
                  "The Internet Site is reserved for the Internet Resource and cannot be used.",
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
              description: "Resource address.",
              nullable: true
            },
            address_description: %Schema{
              type: :string,
              description: "Resource address description",
              nullable: true
            },
            type: %Schema{
              type: :string,
              # A pool may restate its own type but nothing can be converted
              # into one through this API for now. See
              # PortalAPI.ResourceController.Database.reject_device_pool_type/1
              # for what to change to re-enable it.
              description:
                "Resource type. `internet` is accepted only in the Internet Site. " <>
                  "`static_device_pool` is accepted only on a Resource that already is one.",
              enum: ["cidr", "ip", "dns", "internet", "static_device_pool"]
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
                "Site to connect the Resource to. Required. " <>
                  "The Internet Site is reserved for the Internet Resource and cannot be used.",
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
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Resource
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "ResourceListResponse",
      description: "Response schema for multiple Resources",
      type: :object,
      properties: %{
        data: %Schema{description: "Resource details", type: :array, items: Resource.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
