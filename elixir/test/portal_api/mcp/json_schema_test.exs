defmodule PortalAPI.MCP.JSONSchemaTest do
  use ExUnit.Case, async: true

  alias OpenApiSpex.{Reference, Schema}
  alias PortalAPI.MCP.JSONSchema

  test "nullable compositions and enums include an explicit null alternative" do
    for schema <- [
          %Schema{nullable: true, allOf: [%Schema{type: :object}]},
          %Schema{nullable: true, type: :string, enum: ["any", "all"]}
        ] do
      assert %{"anyOf" => [_, %{"type" => "null"}]} = JSONSchema.convert(schema, %{})
    end
  end

  test "preserves additional property schemas and defaults" do
    schema = %Schema{
      type: :object,
      additionalProperties: %Schema{type: :boolean},
      properties: %{enabled: %Schema{type: :boolean, default: false}}
    }

    assert %{
             "additionalProperties" => %{"type" => "boolean"},
             "properties" => %{"enabled" => %{"default" => false}}
           } = JSONSchema.convert(schema, %{})
  end

  test "mutually recursive references resolve within the standalone schema" do
    a = %Reference{"$ref": "#/components/schemas/A"}
    b = %Reference{"$ref": "#/components/schemas/B"}

    schemas = %{
      "A" => %Schema{type: :object, properties: %{b: b}},
      "B" => %Schema{type: :object, properties: %{a: a}}
    }

    converted = JSONSchema.convert(a, schemas)
    assert get_in(converted, ["properties", "b", "properties", "a", "$ref"]) == "#/$defs/A"
    assert get_in(converted, ["$defs", "A", "properties", "b", "properties", "a", "$ref"]) == "#/$defs/A"
  end
end
