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
    alias PortalAPI.Schemas.Policy
    alias Portal.Policies.Postures.Fields

    @field_catalog Fields.registry()
                   |> Enum.sort()
                   |> Enum.map_join("\n\n", fn {provider, fields} ->
                     rows =
                       fields
                       |> Enum.sort()
                       |> Enum.map_join("\n", fn {field, type} ->
                         platforms = Enum.join(Fields.platforms(provider, field), ", ")
                         "| `#{provider}.#{field}` | #{type} | #{platforms} |"
                       end)

                     "### #{provider} fields\n\n| Field | Type | Platforms |\n| --- | --- | --- |\n" <> rows
                   end)

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
      provider's synced device attributes. Every synced provider also has a
      boolean `enrolled` that is true when the provider knows the device.

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
        `firezone.ipv4` takes IPv4 CIDRs only and `firezone.ipv6` IPv6 only.
      * lists of strings: `contains`, `does_not_contain`, `contains_any_of`,
        `contains_all_of`, `is_empty`, `is_not_empty`.
      * JSON attributes: `is_empty`, `is_not_empty`.

      The value `@latest` on `firezone.last_seen_version` stands for the newest
      Client release for the device's platform.

      `enum_string` uses the string operators; `integer` and `float` use the
      numeric operators. `string_array` values use a single string for `contains`
      and `does_not_contain`, or a non-empty string list for `contains_any_of`
      and `contains_all_of`.

      Every attribute also accepts `exists` and `does_not_exist`. These and
      `is_empty` / `is_not_empty` take no value: omit `value` or set it to null.
      Missing attributes fail every operator except `does_not_exist`, including
      negative operators such as `is_not`. A missing provider is evaluated as
      one empty row. Its synthetic `enrolled` field is false, so `enrolled is
      false` can explicitly match an unenrolled device. `not` negates the
      result and can also match missing data; use a positive `enrolled is true`
      check when enrollment is required.

      Leaves that do not apply to the device's platform are removed before
      evaluation, including inside `or` and `not`. An expression with no
      applicable leaves passes. If the platform is unknown, no leaves are
      removed. Supported platforms for each field are listed below.
      Provider `os_up_to_date` fields are computed from known OS releases;
      they are not raw provider attributes.

      When a device matches more than one record of a provider, a leaf holds
      when any record satisfies it. Set `rows` to `all` to require every
      record. Different leaves may match different provider rows; `and` does
      not require one row to satisfy all leaves. `rows` is not allowed for
      `firezone`, which always describes exactly one connecting device.

      Expressions allow at most 10 nested boolean levels and 100 leaves.
      List values contain 1–100 items; strings are at most 1024 bytes and
      regular expressions at most 256 bytes. Unknown fields, incompatible
      operators, invalid values, and exceeded limits return HTTP 422 with
      a path in `validation_errors.postures`.

      Supported fields (generated from the same registry used for validation):

      """ <> @field_catalog,
      type: :object,
      example: %{
        "and" => [
          %{"field" => "intune.enrolled", "op" => "is", "value" => true},
          %{"field" => "intune.compliance_state", "op" => "is", "value" => "compliant", "rows" => "all"},
          %{"field" => "intune.last_sync_at", "op" => "within_last", "value" => "PT24H"},
          %{"or" => [
            %{"field" => "firezone.last_seen_version", "op" => "gte", "value" => "@latest"},
            %{"not" => %{"field" => "firezone.hostname", "op" => "starts_with", "value" => "test-"}}
          ]}
        ]
      },
      oneOf: [Policy.PostureAnd, Policy.PostureOr, Policy.PostureNot, Policy.PostureLeaf]
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
          example: Policy.PostureNode.schema().example,
          anyOf: [Policy.PostureNode, %Schema{type: :object, nullable: true, enum: [nil]}],
          description:
            "Device posture expression required in addition to every entry in conditions. " <>
              "Omit or set to null for no posture requirement. A non-null expression requires " <>
              "the account's device_posture entitlement (Enterprise); otherwise returns HTTP 403. " <>
              "See PolicyPostureNode for fields, operators, platform behavior, and limits."
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
          example: Policy.PostureNode.schema().example,
          anyOf: [Policy.PostureNode, %Schema{type: :object, nullable: true, enum: [nil]}],
          description:
            "Replaces the entire device posture expression; it is not merged. Omit to preserve " <>
              "existing postures, or set to null to remove them. A non-null expression requires " <>
              "the account's device_posture entitlement (Enterprise); otherwise returns HTTP 403. " <>
              "Clearing postures remains allowed after downgrade. Conditions and postures must " <>
              "both hold. Changing postures revokes this policy's active authorizations and " <>
              "interrupts affected connections until they are reauthorized. See PolicyPostureNode " <>
              "for fields, operators, platform behavior, and limits."
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
          example: Policy.PostureNode.schema().example,
          anyOf: [Policy.PostureNode, %Schema{type: :object, nullable: true, enum: [nil]}],
          description:
            "The stored device posture expression, or null when none is required. " <>
              "The connecting device must satisfy this expression and every entry in conditions. " <>
              "Returned on create, update, show, and list, including after an account downgrade."
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
