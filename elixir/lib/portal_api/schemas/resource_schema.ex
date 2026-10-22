defmodule PortalAPI.Schemas.Resource do
  alias OpenApiSpex.Schema

  defmodule DeviceMembershipCriteria do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DeviceMembershipCriteria",
      description: """
      Who a `device_pool` Resource holds. Required for a device pool, absent for every
      other Resource type.

      The object has exactly one key, naming where the field lives: `device` is the
      Client row itself, and `actor_group` is a group the Client's owner belongs to.
      The value is one rule comparing a field against either a literal or an attribute
      of the Actor asking for access. More sources can be added later without changing
      the rules already stored.

      The four rules the API accepts, and who each one holds:

          {"device": {"field": "id", "op": "in", "value": ["<client id>", ...]}}
          {"device": {"field": "actor_id", "op": "eq", "value": {"subject": "actor_id"}}}
          {"device": {"field": "account_id", "op": "eq", "value": {"subject": "account_id"}}}
          {"actor_group": {"field": "id", "op": "eq", "value": "<group id>"}}

      In order: exactly the Clients named, the asking Actor's own Clients, every Client
      in the Account, and the Clients of every Actor in one Group.

      Editing the list of Clients the first rule names drops the connections to the
      Clients removed and leaves every other connection through the pool alone.

      Every other change to this field is a breaking update, because any Client can move
      in or out of the pool: every active connection through the pool is dropped, and
      Clients reconnect to the members they may still reach.

      Clients older than the device-pool protocol only understand a pool that names its
      members, so they are sent the first rule and never the other three.
      """,
      type: :object,
      example: %{
        "device" => %{"field" => "actor_id", "op" => "eq", "value" => %{"subject" => "actor_id"}}
      },
      oneOf: [
        %Schema{
          title: "DeviceMembershipListedDevices",
          description: "Exactly the Clients named",
          type: :object,
          additionalProperties: false,
          example: %{
            "device" => %{
              "field" => "id",
              "op" => "in",
              "value" => [
                "7cb89288-1fb3-433e-a522-2d087e45988d",
                "cc9f561a-444d-4083-ab38-0abc6cf2314c"
              ]
            }
          },
          properties: %{
            device: %Schema{
              type: :object,
              additionalProperties: false,
              properties: %{
                field: %Schema{type: :string, enum: ["id"]},
                op: %Schema{type: :string, enum: ["in"]},
                value: %Schema{
                  type: :array,
                  description: "Client IDs",
                  items: %Schema{type: :string, format: :uuid}
                }
              },
              required: [:field, :op, :value]
            }
          },
          required: [:device]
        },
        %Schema{
          title: "DeviceMembershipOwnDevices",
          description: "The Clients of the Actor asking for access",
          type: :object,
          additionalProperties: false,
          example: %{
            "device" => %{"field" => "actor_id", "op" => "eq", "value" => %{"subject" => "actor_id"}}
          },
          properties: %{
            device: %Schema{
              type: :object,
              additionalProperties: false,
              properties: %{
                field: %Schema{type: :string, enum: ["actor_id"]},
                op: %Schema{type: :string, enum: ["eq"]},
                value: %Schema{
                  type: :object,
                  additionalProperties: false,
                  properties: %{subject: %Schema{type: :string, enum: ["actor_id"]}},
                  required: [:subject]
                }
              },
              required: [:field, :op, :value]
            }
          },
          required: [:device]
        },
        %Schema{
          title: "DeviceMembershipAllDevices",
          description: "Every Client in the Account",
          type: :object,
          additionalProperties: false,
          example: %{
            "device" => %{
              "field" => "account_id",
              "op" => "eq",
              "value" => %{"subject" => "account_id"}
            }
          },
          properties: %{
            device: %Schema{
              type: :object,
              additionalProperties: false,
              properties: %{
                field: %Schema{type: :string, enum: ["account_id"]},
                op: %Schema{type: :string, enum: ["eq"]},
                value: %Schema{
                  type: :object,
                  additionalProperties: false,
                  properties: %{subject: %Schema{type: :string, enum: ["account_id"]}},
                  required: [:subject]
                }
              },
              required: [:field, :op, :value]
            }
          },
          required: [:device]
        },
        %Schema{
          title: "DeviceMembershipActorGroup",
          description: "The Clients of every Actor in one Group",
          type: :object,
          additionalProperties: false,
          example: %{
            "actor_group" => %{
              "field" => "id",
              "op" => "eq",
              "value" => "b3a1c6e2-5f4d-4e7a-9c8b-1d2e3f4a5b6c"
            }
          },
          properties: %{
            actor_group: %Schema{
              type: :object,
              additionalProperties: false,
              properties: %{
                field: %Schema{type: :string, enum: ["id"]},
                op: %Schema{type: :string, enum: ["eq"]},
                value: %Schema{type: :string, format: :uuid, description: "Group ID"}
              },
              required: [:field, :op, :value]
            }
          },
          required: [:actor_group]
        }
      ]
    })
  end

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.Resource,
             internal: [:account_id, :inserted_at, :updated_at]}
    OpenApiSpex.schema(%{
      title: "Resource",
      description: "Resource",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Resource ID"
        },
        name: %Schema{example: "Prod DB", type: :string, description: "Resource name"},
        address: %Schema{
          example: "10.0.0.10",
          type: :string,
          nullable: true,
          description: "Resource address. Null for `device_pool` Resources."
        },
        address_description: %Schema{
          example: "Production Database",
          type: :string,
          nullable: true,
          description: "Resource address description"
        },
        type: %Schema{
          example: "ip",
          type: :string,
          description:
            "Resource type. A `device_pool` has no `address` and no `site_id`; who it " <>
              "holds is `device_membership_criteria`.",
          enum: ["cidr", "ip", "dns", "internet", "device_pool"]
        },
        device_membership_criteria: PortalAPI.Schemas.Resource.DeviceMembershipCriteria,
        ip_stack: %Schema{
          type: :string,
          description: "IP stack type. Only supported for DNS resources.",
          enum: ["ipv4_only", "ipv6_only", "dual"]
        },
        site_id: %Schema{
          example: "0642e09d-b3a2-47e4-9cd1-c2195faeeb67",
          title: "SiteID",
          description:
            "Site to connect the Resource to. Required for all types except device pools.",
          type: :string,
          format: :uuid
        },
        filters: %Schema{
          example: [
            %{"protocol" => "tcp", "ports" => ["5432"]}
          ],
          type: :array,
          description: "Traffic filters restricting the protocols and ports the Resource exposes",
          items: PortalAPI.Schemas.Resource.Filter
        }
      },
      required: [:address, :address_description, :filters, :id, :name, :type]
    })

    def map(%Portal.Resource{filters: filters} = resource, _map) do
      %{
        filters: Enum.map(filters, &%{protocol: &1.protocol, ports: &1.ports}),
        device_membership_criteria: render_criteria(resource.device_membership_criteria)
      }
    end

    defp render_criteria(nil), do: nil

    defp render_criteria(criteria),
      do: Portal.Resource.DeviceMembershipCriteria.to_map(criteria)
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
          example: "tcp",
          type: :string,
          description: "Transport protocol the filter applies to",
          enum: ["tcp", "udp", "icmp"]
        },
        ports: %Schema{
          example: ["80", "443", "8000 - 9000"],
          type: :array,
          description:
            "Port numbers or ranges (e.g. `80` or `8000 - 9000`) the filter allows. " <>
              "Not applicable to `icmp`.",
          items: %Schema{type: :string}
        }
      },
      required: [:protocol]
    })
  end

  defmodule CreateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Resource

    OpenApiSpex.schema(%{
      title: "ResourceCreateRequest",
      description:
        "POST body for creating a Resource. `site_id` is required for every type " <>
          "except `device_pool`, which needs `device_membership_criteria` instead.",
      type: :object,
      properties: %{
        resource: %Schema{
          type: :object,
          properties: %{
            name: %Schema{
              example: "Prod DB",
              type: :string,
              description: "Resource name"
            },
            address: %Schema{
              example: "10.0.0.10",
              type: :string,
              description:
                "Resource address. Required for `cidr`, `ip` and `dns`. " <>
                  "`device_pool` and `internet` Resources ignore it.",
              nullable: true
            },
            address_description: %Schema{
              example: "Production Database",
              type: :string,
              description: "Resource address description",
              nullable: true
            },
            type: %Schema{
              example: "ip",
              type: :string,
              description:
                "Resource type. `internet` is accepted only in the Internet Site. " <>
                  "`device_pool` takes no `site_id` and no `address`.",
              enum: ["cidr", "ip", "dns", "internet", "device_pool"]
            },
            ip_stack: %Schema{
              type: :string,
              description: "IP stack type. Only supported for DNS resources.",
              enum: ["ipv4_only", "ipv6_only", "dual"],
              nullable: true
            },
            site_id: %Schema{
              example: "0642e09d-b3a2-47e4-9cd1-c2195faeeb67",
              title: "SiteID",
              description:
                "Site to connect the Resource to. Required for all types except `device_pool`, " <>
                  "which takes none. The Internet Site is reserved for the Internet Resource " <>
                  "and cannot be used.",
              type: :string,
              format: :uuid,
              nullable: true
            },
            filters: %Schema{
              example: [
                %{"protocol" => "tcp", "ports" => ["5432"]}
              ],
              type: :array,
              description:
                "Traffic filters restricting the protocols and ports the Resource exposes",
              items: Resource.Filter
            },
            device_membership_criteria: Resource.DeviceMembershipCriteria
          },
          required: [:name, :type]
        }
      },
      required: [:resource]
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
            name: %Schema{
              example: "Prod DB",
              type: :string,
              description: "Resource name"
            },
            address: %Schema{
              example: "10.0.0.10",
              type: :string,
              description:
                "Resource address. Required for `cidr`, `ip` and `dns`. " <>
                  "`device_pool` and `internet` Resources ignore it.",
              nullable: true
            },
            address_description: %Schema{
              example: "Production Database",
              type: :string,
              description: "Resource address description",
              nullable: true
            },
            type: %Schema{
              example: "ip",
              type: :string,
              description:
                "Resource type. `internet` is accepted only in the Internet Site. " <>
                  "`device_pool` takes no `site_id` and no `address`.",
              enum: ["cidr", "ip", "dns", "internet", "device_pool"]
            },
            ip_stack: %Schema{
              type: :string,
              description: "IP stack type. Only supported for DNS resources.",
              enum: ["ipv4_only", "ipv6_only", "dual"],
              nullable: true
            },
            site_id: %Schema{
              example: "0642e09d-b3a2-47e4-9cd1-c2195faeeb67",
              title: "SiteID",
              description:
                "Site to connect the Resource to. Required for all types except `device_pool`, " <>
                  "which takes none. The Internet Site is reserved for the Internet Resource " <>
                  "and cannot be used.",
              type: :string,
              format: :uuid,
              nullable: true
            },
            filters: %Schema{
              example: [
                %{"protocol" => "tcp", "ports" => ["5432"]}
              ],
              type: :array,
              description:
                "Traffic filters restricting the protocols and ports the Resource exposes",
              items: Resource.Filter
            },
            device_membership_criteria: Resource.DeviceMembershipCriteria
          }
        }
      },
      required: [:resource]
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
