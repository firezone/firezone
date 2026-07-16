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
      """,
      type: :object,
      properties: %{
        property: %Schema{
          type: :string,
          description: "The attribute of the connection being matched against",
          enum: [
            "remote_ip_location_region",
            "remote_ip",
            "auth_provider_id",
            "current_utc_datetime",
            "client_verified"
          ]
        },
        operator: %Schema{
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
          type: :array,
          description: "The values to compare against, interpreted per the property",
          items: %Schema{type: :string}
        }
      },
      required: [:property, :operator, :values],
      example: %{
        "property" => "remote_ip_location_region",
        "operator" => "is_in",
        "values" => ["US", "CA"]
      }
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
        group_id: %Schema{type: :string, format: :uuid, description: "Group ID"},
        resource_id: %Schema{type: :string, format: :uuid, description: "Resource ID"},
        description: %Schema{type: :string, description: "Policy Description", nullable: true},
        flow_log_uploads_enabled: %Schema{
          type: :boolean,
          description:
            "Whether flow logs are reported for connections authorized by this Policy. " <>
              "Defaults to true. Always false for Internet Resource policies.",
          default: true
        },
        conditions: %Schema{
          type: :array,
          description: "Conditions that must be satisfied for the Policy to grant access",
          items: Policy.Condition
        }
      },
      required: [:group_id, :resource_id],
      example: %{
        "group_id" => "88eae9ce-9179-48c6-8430-770e38dd4775",
        "resource_id" => "a9f60587-793c-46ae-8525-597f43ab2fb1",
        "description" => "Policy to allow something",
        "flow_log_uploads_enabled" => true,
        "conditions" => [
          %{
            "property" => "remote_ip_location_region",
            "operator" => "is_in",
            "values" => ["US", "CA"]
          }
        ]
      }
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
        description: %Schema{type: :string, description: "Policy Description", nullable: true},
        flow_log_uploads_enabled: %Schema{
          type: :boolean,
          description:
            "Whether flow logs are reported for connections authorized by this Policy. " <>
              "Always false for Internet Resource policies."
        },
        conditions: %Schema{
          type: :array,
          description: "Conditions that must be satisfied for the Policy to grant access",
          items: Policy.Condition
        }
      },
      example: %{
        "description" => "Updated description",
        "conditions" => [
          %{
            "property" => "remote_ip",
            "operator" => "is_in_cidr",
            "values" => ["10.0.0.0/8"]
          }
        ]
      }
    })
  end

  defmodule ResponseSchema do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.Policy

    OpenApiSpex.schema(%{
      title: "Policy",
      description: "Policy",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Policy ID"},
        group_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description:
            "Group ID. Null if the Group was deleted during directory sync; it is relinked " <>
              "automatically if the Group reappears on a subsequent sync."
        },
        resource_id: %Schema{type: :string, format: :uuid, description: "Resource ID"},
        description: %Schema{type: :string, description: "Policy Description", nullable: true},
        flow_log_uploads_enabled: %Schema{
          type: :boolean,
          description: "Whether flow logs are reported for connections authorized by this Policy"
        },
        conditions: %Schema{
          type: :array,
          description: "Conditions that must be satisfied for the Policy to grant access",
          items: Policy.Condition
        }
      },
      required: [:id, :group_id, :resource_id, :description, :flow_log_uploads_enabled, :conditions],
      example: %{
        "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
        "group_id" => "88eae9ce-9179-48c6-8430-770e38dd4775",
        "resource_id" => "a9f60587-793c-46ae-8525-597f43ab2fb1",
        "description" => "Policy to allow something",
        "flow_log_uploads_enabled" => true,
        "conditions" => [
          %{
            "property" => "remote_ip_location_region",
            "operator" => "is_in",
            "values" => ["US", "CA"]
          }
        ]
      }
    })
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
      required: [:policy],
      example: %{
        "policy" => %{
          "resource_id" => "a9f60587-793c-46ae-8525-597f43ab2fb1",
          "group_id" => "88eae9ce-9179-48c6-8430-770e38dd4775",
          "description" => "Policy to allow something",
          "conditions" => [
            %{
              "property" => "remote_ip_location_region",
              "operator" => "is_in",
              "values" => ["US", "CA"]
            }
          ]
        }
      }
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
      required: [:policy],
      example: %{
        "policy" => %{
          "description" => "Updated description",
          "conditions" => [
            %{
              "property" => "remote_ip",
              "operator" => "is_in_cidr",
              "values" => ["10.0.0.0/8"]
            }
          ]
        }
      }
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
        data: Policy.ResponseSchema
      },
      example: %{
        "data" => %{
          "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          "resource_id" => "a9f60587-793c-46ae-8525-597f43ab2fb1",
          "group_id" => "88eae9ce-9179-48c6-8430-770e38dd4775",
          "description" => "Policy to allow something",
          "flow_log_uploads_enabled" => true,
          "conditions" => [
            %{
              "property" => "remote_ip_location_region",
              "operator" => "is_in",
              "values" => ["US", "CA"]
            }
          ]
        }
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
        data: %Schema{description: "Policy details", type: :array, items: Policy.ResponseSchema},
        metadata: PaginationMetadata
      },
      example: %{
        "data" => [
          %{
            "id" => "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
            "resource_id" => "a9f60587-793c-46ae-8525-597f43ab2fb1",
            "group_id" => "88eae9ce-9179-48c6-8430-770e38dd4775",
            "description" => "Policy to allow something",
            "flow_log_uploads_enabled" => true,
            "conditions" => [
              %{
                "property" => "remote_ip_location_region",
                "operator" => "is_in",
                "values" => ["US", "CA"]
              }
            ]
          },
          %{
            "id" => "6301d7d2-4938-4123-87de-282c01cca656",
            "resource_id" => "9876bd25-0f6c-48fb-a9fd-196ba9be86e5",
            "group_id" => "343385a2-5437-4c66-8744-1332421ff736",
            "description" => "Policy to allow something else",
            "flow_log_uploads_enabled" => false,
            "conditions" => []
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
