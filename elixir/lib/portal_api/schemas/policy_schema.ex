defmodule PortalAPI.Schemas.Policy do
  alias OpenApiSpex.Schema

  defmodule Condition do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "PolicyCondition",
      description: """
      A condition that must be satisfied for the Policy to grant access.

      All conditions on a Policy must evaluate to true for access to be
      granted. A condition is made up of a `property`, an `operator`, and a
      list of `values`. The valid operators and the meaning of `values`
      depend on the `property`:

      * `remote_ip_location_region` with `is_in` / `is_not_in`: `values` are
        ISO 3166-1 alpha-2 country codes, e.g. `["US", "CA"]`.
      * `remote_ip` with `is_in_cidr` / `is_not_in_cidr`: `values` are CIDR
        ranges (IPv4 or IPv6), e.g. `["10.0.0.0/8", "2607:f8b0::/32"]`.
      * `auth_provider_id` with `is_in` / `is_not_in`: `values` are
        authentication provider IDs (UUIDs).
      * `current_utc_datetime` with `is_in_day_of_week_time_ranges`: each
        value is a `DAY/TIME_RANGES/TIMEZONE` string where `DAY` is one of
        `M T W R F S U` (Monday through Sunday), `TIME_RANGES` is a
        comma-separated list of `HH:MM-HH:MM` ranges, and `TIMEZONE` is an
        IANA timezone name, e.g. `"M/09:00-17:00/America/New_York"`.
      * `client_verified` with `is`: `values` is a single-element list
        containing `"true"` or `"false"`.
      * `device_attested` with `is`: `values` is a single-element list
        containing `"true"` or `"false"`. `"true"` requires the Client to
        have presented a valid X.509 certificate from one of the account's
        trust anchors on its current connection.
      """,
      type: :object,
      properties: %{
        property: %Schema{
          example: "remote_ip_location_region",
          type: :string,
          description: "The attribute of the connection being matched against",
          enum: [
            "remote_ip_location_region",
            "remote_ip",
            "auth_provider_id",
            "current_utc_datetime",
            "client_verified",
            "device_attested"
          ]
        },
        operator: %Schema{
          example: "is_in",
          type: :string,
          description: "How the values are compared against the property",
          enum: [
            "is_in",
            "is_not_in",
            "is_in_cidr",
            "is_not_in_cidr",
            "is_in_day_of_week_time_ranges",
            "is"
          ]
        },
        values: %Schema{
          example: ["US", "CA"],
          type: :array,
          description: "The values to compare against, interpreted per the property",
          items: %Schema{type: :string}
        }
      },
      required: [:property, :operator, :values]
    })
  end

  defmodule PostureNode do
    require OpenApiSpex
    alias OpenApiSpex.{Reference, Schema}
    alias Portal.Policies.Postures.Fields

    @node %Reference{"$ref": "#/components/schemas/PolicyPostureNode"}
    @operators Enum.map(Fields.operators(), &Atom.to_string/1)

    OpenApiSpex.schema(%{
      title: "PolicyPostureNode",
      description: """
      One node of a Policy's device posture expression. A node has exactly one
      of these shapes:

      * `and`: a non-empty list of nodes that must all hold.
      * `or`: a non-empty list of nodes of which at least one must hold.
      * `not`: a node that must not hold.
      * a leaf: a `field`, an `op`, and for most operators a `value`.

      A leaf's `field` is `<provider>.<attribute>`, such as
      `intune.compliance_state` or `firezone.last_seen_version`. The provider
      is one of `firezone` (the connecting device's own record), `intune`,
      `iru`, `defender`, `santa` or `sentinelone`. The attribute is one of that
      provider's synced device attributes. Every provider also has a boolean
      `enrolled` that is true when the provider knows the device.

      The attribute's type decides which operators apply and what `value`
      must be:

      * strings: `is`, `is_not`, `is_in`, `is_not_in`, `contains`,
        `does_not_contain`, `starts_with`, `ends_with`, `matches`,
        `does_not_match`. Comparisons ignore case. `is_in` and `is_not_in`
        take a list of strings. `matches` and `does_not_match` take a regular
        expression.
      * booleans: `is` with `true` or `false`.
      * numbers: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`.
      * versions: `is`, `is_not`, `gt`, `gte`, `lt`, `lte`, compared segment
        by segment, so `14.4` equals `14.4.0`.
      * timestamps: `before` and `after` with an ISO 8601 datetime such as
        `2026-01-01T00:00:00Z`; `within_last` and `not_within_last` with an
        ISO 8601 duration such as `PT24H` or `P30D`. A date-only attribute
        counts as the start of that day in UTC.
      * IP addresses: `is_in_cidr` and `is_not_in_cidr` with a list of CIDRs.
      * lists of strings: `contains`, `does_not_contain`, `contains_any_of`,
        `contains_all_of`, `is_empty`, `is_not_empty`.
      * JSON attributes: `is_empty`, `is_not_empty`.

      Every attribute also accepts `exists` and `does_not_exist`, which take
      no value. An attribute the provider did not report fails every other
      operator, so a device the provider does not know never passes.

      When a device matches more than one record of a provider, a leaf holds
      when any record satisfies it. Set `rows` to `all` to require every
      record. An expression may nest 10 levels deep and hold 100 leaves.
      """,
      type: :object,
      example: %{
        "and" => [
          %{"field" => "intune.compliance_state", "op" => "is", "value" => "compliant"},
          %{"field" => "intune.last_sync_date_time", "op" => "within_last", "value" => "PT24H"},
          %{"not" => %{"field" => "firezone.attested", "op" => "is", "value" => false}}
        ]
      },
      properties: %{
        and: %Schema{
          type: :array,
          items: @node,
          minItems: 1,
          description: "Nodes that must all hold"
        },
        or: %Schema{
          type: :array,
          items: @node,
          minItems: 1,
          description: "Nodes of which at least one must hold"
        },
        not: @node,
        field: %Schema{
          type: :string,
          example: "intune.compliance_state",
          description: "The provider attribute a leaf tests, as `<provider>.<attribute>`"
        },
        op: %Schema{
          type: :string,
          example: "is",
          enum: @operators,
          description: "How the attribute is compared to the value"
        },
        value: %Schema{
          example: "compliant",
          description:
            "What the attribute is compared to: a string, number, boolean or list, as the operator requires"
        },
        rows: %Schema{
          type: :string,
          enum: ["any", "all"],
          default: "any",
          description:
            "Whether any or every record of the provider must satisfy the leaf when several match the device"
        }
      },
      additionalProperties: false
    })
  end

  defmodule CreateParams do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy

    OpenApiSpex.schema(%{
      title: "PolicyCreateParams",
      description: "Policy attributes accepted when creating a Policy",
      type: :object,
      properties: %{
        group_id: %Schema{
          example: "88eae9ce-9179-48c6-8430-770e38dd4775",
          type: :string,
          format: :uuid,
          description: "Group ID"
        },
        resource_id: %Schema{
          example: "a9f60587-793c-46ae-8525-597f43ab2fb1",
          type: :string,
          format: :uuid,
          description: "Resource ID"
        },
        description: %Schema{
          example: "Policy to allow something",
          type: :string,
          description: "Policy Description",
          nullable: true
        },
        flow_log_uploads_enabled: %Schema{
          example: true,
          type: :boolean,
          description:
            "Whether flow logs are reported for connections authorized by this Policy. " <>
              "Defaults to true. Always false for Internet Resource policies.",
          default: true
        },
        is_disabled: %Schema{
          example: false,
          type: :boolean,
          description:
            "Whether the Policy is disabled. A disabled Policy grants no access but is " <>
              "otherwise retained. Defaults to false.",
          default: false
        },
        postures: %Schema{
          allOf: [Policy.PostureNode],
          nullable: true,
          description:
            "Device posture the connecting device must satisfy, or null when none is required. " <>
              "Requires the device posture feature."
        },
        conditions: %Schema{
          example: [
            %{
              "property" => "remote_ip_location_region",
              "operator" => "is_in",
              "values" => ["US", "CA"]
            }
          ],
          type: :array,
          description: "Conditions that must be satisfied for the Policy to grant access",
          items: Policy.Condition
        }
      },
      required: [:group_id, :resource_id]
    })
  end

  defmodule UpdateParams do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy

    OpenApiSpex.schema(%{
      title: "PolicyUpdateParams",
      description:
        "Policy attributes accepted when updating a Policy. All fields are " <>
          "optional; omitted fields keep their current value.",
      type: :object,
      properties: %{
        group_id: %Schema{type: :string, format: :uuid, description: "Group ID"},
        resource_id: %Schema{type: :string, format: :uuid, description: "Resource ID"},
        description: %Schema{
          example: "Updated description",
          type: :string,
          description: "Policy Description",
          nullable: true
        },
        flow_log_uploads_enabled: %Schema{
          type: :boolean,
          description:
            "Whether flow logs are reported for connections authorized by this Policy. " <>
              "Always false for Internet Resource policies."
        },
        is_disabled: %Schema{
          example: false,
          type: :boolean,
          description:
            "Whether the Policy is disabled. A disabled Policy grants no access but is " <>
              "otherwise retained.",
          default: false
        },
        postures: %Schema{
          allOf: [Policy.PostureNode],
          nullable: true,
          description:
            "Device posture the connecting device must satisfy, or null when none is required. " <>
              "Requires the device posture feature."
        },
        conditions: %Schema{
          example: [
            %{
              "property" => "remote_ip",
              "operator" => "is_in_cidr",
              "values" => ["10.0.0.0/8"]
            }
          ],
          type: :array,
          description: "Conditions that must be satisfied for the Policy to grant access",
          items: Policy.Condition
        }
      }
    })
  end

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.Policy, internal: [:account_id, :group_idp_id, :inserted_at, :updated_at]}
    OpenApiSpex.schema(%{
      title: "Policy",
      description: "Policy",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Policy ID"
        },
        group_id: %Schema{
          example: "88eae9ce-9179-48c6-8430-770e38dd4775",
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Group ID. Null if the Group was deleted during directory sync; it is relinked " <>
              "automatically if the Group reappears on a subsequent sync."
        },
        resource_id: %Schema{
          example: "a9f60587-793c-46ae-8525-597f43ab2fb1",
          type: :string,
          format: :uuid,
          description: "Resource ID"
        },
        description: %Schema{
          example: "Policy to allow something",
          type: :string,
          description: "Policy Description",
          nullable: true
        },
        flow_log_uploads_enabled: %Schema{
          example: true,
          type: :boolean,
          description: "Whether flow logs are reported for connections authorized by this Policy"
        },
        is_disabled: %Schema{
          example: false,
          type: :boolean,
          description:
            "Whether the Policy is disabled. A disabled Policy grants no access but is " <>
              "otherwise retained."
        },
        postures: %Schema{
          allOf: [Policy.PostureNode],
          nullable: true,
          description:
            "Device posture the connecting device must satisfy, or null when none is required. " <>
              "Requires the device posture feature."
        },
        conditions: %Schema{
          example: [
            %{
              "property" => "remote_ip_location_region",
              "operator" => "is_in",
              "values" => ["US", "CA"]
            }
          ],
          type: :array,
          description: "Conditions that must be satisfied for the Policy to grant access",
          items: Policy.Condition
        }
      },
      required: [
        :conditions,
        :description,
        :flow_log_uploads_enabled,
        :group_id,
        :id,
        :is_disabled,
        :postures,
        :resource_id
      ]
    })

    def map(%Portal.Policy{conditions: conditions}, _map) do
      %{
        conditions:
          Enum.map(
            conditions,
            &%{property: &1.property, operator: &1.operator, values: &1.values}
          )
      }
    end
  end

  defmodule CreateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy

    OpenApiSpex.schema(%{
      title: "PolicyCreateRequest",
      description: "POST body for creating a Policy",
      type: :object,
      properties: %{
        policy: Policy.CreateParams
      },
      required: [:policy]
    })
  end

  defmodule UpdateRequest do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy

    OpenApiSpex.schema(%{
      title: "PolicyUpdateRequest",
      description: "PUT/PATCH body for updating a Policy",
      type: :object,
      properties: %{
        policy: Policy.UpdateParams
      },
      required: [:policy]
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy

    OpenApiSpex.schema(%{
      title: "PolicyResponse",
      description: "Response schema for single Policy",
      type: :object,
      properties: %{
        data: Policy.Schema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "PolicyListResponse",
      description: "Response schema for multiple Policies",
      type: :object,
      properties: %{
        data: %Schema{description: "Policy details", type: :array, items: Policy.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
