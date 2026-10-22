defmodule PortalAPI.Schemas.PostureField do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias Portal.Policies.Postures.Fields

    OpenApiSpex.schema(%{
      title: "PostureField",
      description: "A field a Policy's `postures` expression can test",
      type: :object,
      properties: %{
        field: %Schema{
          example: "intune.compliance_state",
          type: :string,
          description: "Value for a leaf's `field`, as `<provider>.<attribute>`"
        },
        provider: %Schema{
          example: "intune",
          type: :string,
          enum: Enum.map(Fields.providers(), &Atom.to_string/1),
          description: "Provider the field comes from"
        },
        type: %Schema{
          example: "enum_string",
          type: :string,
          enum: Enum.map(Fields.types(), &Atom.to_string/1),
          description: "Type of the field, which decides the operators and the value"
        },
        operators: %Schema{
          example: ["is", "is_not", "exists", "does_not_exist"],
          type: :array,
          items: %Schema{type: :string, enum: Enum.map(Fields.operators(), &Atom.to_string/1)},
          description: "Values for a leaf's `op` that this field accepts"
        },
        platforms: %Schema{
          example: ["windows", "macos", "ios", "android"],
          type: :array,
          items: %Schema{type: :string, enum: Enum.map(Fields.platforms(), &Atom.to_string/1)},
          description:
            "Platforms the field applies to. A leaf on this field is skipped for a device on " <>
              "any other platform."
        },
        rows_supported: %Schema{
          example: true,
          type: :boolean,
          description:
            "Whether a leaf on this field accepts `rows`. False for `firezone` fields, which " <>
              "describe exactly one connecting device."
        }
      },
      required: [:field, :provider, :type, :operators, :platforms, :rows_supported]
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PostureField

    OpenApiSpex.schema(%{
      title: "PostureFieldListResponse",
      description: "Response schema for every Posture Field",
      type: :object,
      properties: %{
        data: %Schema{description: "Posture Fields", type: :array, items: PostureField.Schema}
      },
      required: [:data]
    })
  end
end
