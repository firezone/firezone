defmodule PortalAPI.Schemas.Policy.PostureAnd do
  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "PolicyPostureAnd",
    description: "Every applicable child expression must hold. Contains no other keys.",
    type: :object,
    properties: %{
      and: %Schema{
        type: :array,
        minItems: 1,
        maxItems: 100,
        items: %Reference{"$ref": "#/components/schemas/PolicyPostureNode"}
      }
    },
    required: [:and],
    additionalProperties: false
  })
end

defmodule PortalAPI.Schemas.Policy.PostureOr do
  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "PolicyPostureOr",
    description: "At least one applicable child expression must hold. Contains no other keys.",
    type: :object,
    properties: %{
      or: %Schema{
        type: :array,
        minItems: 1,
        maxItems: 100,
        items: %Reference{"$ref": "#/components/schemas/PolicyPostureNode"}
      }
    },
    required: [:or],
    additionalProperties: false
  })
end

defmodule PortalAPI.Schemas.Policy.PostureNot do
  require OpenApiSpex
  alias OpenApiSpex.Reference

  OpenApiSpex.schema(%{
    title: "PolicyPostureNot",
    description: "Negates one applicable expression. Contains no other keys.",
    type: :object,
    properties: %{not: %Reference{"$ref": "#/components/schemas/PolicyPostureNode"}},
    required: [:not],
    additionalProperties: false
  })
end

defmodule PortalAPI.Schemas.Policy.PostureLeaf do
  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias Portal.Policies.Postures
  alias Portal.Policies.Postures.Fields

  # Generate the field and operator alternatives from the evaluator's registry
  # so adding telemetry cannot silently leave the REST or MCP schema behind.
  @field_groups (for {provider, fields} <- Fields.registry(), {field, type} <- fields do
                   {"#{provider}.#{field}", type, provider == :firezone}
                 end)
                |> Enum.group_by(fn {_field, type, single_row?} -> {type, single_row?} end,
                  fn {field, _type, _single_row?} -> field end)
                |> Enum.sort()

  @string %Schema{type: :string, maxLength: 1024}
  @scalar_values %{
    string: @string,
    enum_string: @string,
    boolean: %Schema{type: :boolean},
    integer: %Schema{type: :integer},
    float: %Schema{type: :number},
    version: %Schema{type: :string, maxLength: 1024, description: "Segment-wise version, or @latest for firezone.last_seen_version only"},
    datetime: %Schema{type: :string, format: :"date-time", maxLength: 1024},
    string_array: @string
  }

  @variants (for {{type, single_row?}, fields} <- @field_groups,
                {kind, operators} <-
                  Fields.operators(type)
                  |> Enum.group_by(fn op ->
                    cond do
                      op in Postures.no_value_operators() -> :no_value
                      op in Postures.list_operators() -> :list
                      op in [:matches, :does_not_match] -> :regex
                      op in [:within_last, :not_within_last] -> :duration
                      true -> :scalar
                    end
                  end)
                  |> Enum.sort() do
              value =
                case kind do
                  :no_value -> %Schema{type: :object, nullable: true, enum: [nil], description: "Omit value or use null for this operator"}
                  :list -> %Schema{type: :array, minItems: 1, maxItems: 100, items: @string}
                  :regex -> %Schema{type: :string, maxLength: 256, description: "Regular expression; at most 256 bytes"}
                  :duration -> %Schema{type: :string, maxLength: 1024, description: "Positive ISO 8601 duration, such as PT24H or P30D"}
                  :scalar -> Map.fetch!(@scalar_values, type)
                end

              properties = %{
                field: %Schema{type: :string, enum: Enum.sort(fields), description: "#{type} field; see PolicyPostureNode for platform applicability"},
                op: %Schema{type: :string, enum: Enum.map(operators, &Atom.to_string/1)},
                value: value
              }

              properties =
                if single_row? do
                  properties
                else
                  Map.put(properties, :rows, %Schema{
                    type: :string,
                    enum: ["any", "all"],
                    default: "any",
                    description: "Match any or every provider row; applies to this leaf independently"
                  })
                end

              %Schema{
                title: "#{type} #{kind} #{if single_row?, do: "device", else: "provider"} comparison",
                type: :object,
                properties: properties,
                required: if(kind == :no_value, do: [:field, :op], else: [:field, :op, :value]),
                additionalProperties: false
              }
            end)

  OpenApiSpex.schema(%{
    title: "PolicyPostureLeaf",
    description: """
    One typed comparison. Each alternative enumerates valid fields, their
    operators, and the corresponding value type. All keys are explicit;
    unknown keys are rejected. Provider comparisons optionally accept `rows`;
    Firezone device comparisons do not.

    Value length limits are enforced in bytes by the policy parser, including
    each string in a list. The parser additionally checks regex syntax,
    versions, CIDR address families, positive durations, and the `@latest`
    macro. See PolicyPostureNode for platform and missing-data semantics.
    """,
    type: :object,
    oneOf: @variants,
    example: %{"field" => "intune.compliance_state", "op" => "is", "value" => "compliant", "rows" => "all"}
  })
end
