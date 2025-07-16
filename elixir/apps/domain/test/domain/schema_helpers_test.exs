defmodule Domain.SchemaHelpersTest do
  use ExUnit.Case, async: true

  alias Domain.SchemaHelpers

  # --- Test Schemas ---

  defmodule NestedEmbedSchema do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :nested_field, :string
    end

    def changeset(struct, params) do
      cast(struct, params, [:nested_field])
    end
  end

  defmodule EmbeddedSchema do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :sub_field1, :string
      field :sub_field2, :string
      embeds_one :nested_item, NestedEmbedSchema
    end

    def changeset(struct, params) do
      struct
      |> cast(params, [:sub_field1, :sub_field2])
      |> cast_embed(:nested_item)
    end
  end

  defmodule ListItemSchema do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :list_field1, :string
      field :list_field2, :string, default: "default_value"
    end

    def changeset(struct, params) do
      cast(struct, params, [:list_field1, :list_field2])
    end
  end

  defmodule NestedEnumSchema do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :enum_field, Ecto.Enum, values: ~w[option1 option2 option3]a
      field :values, {:array, :string}
    end
  end

  defmodule RootSchema do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :field1, :string
      field :field2, :integer
      field :field3, :boolean, default: false
      embeds_one :embedded_item, EmbeddedSchema
      embeds_many :list_items, ListItemSchema
    end
  end

  # --- Test Cases ---

  describe "struct_from_params/2" do
    test "correctly casts basic types from string-keyed map" do
      params = %{
        "field1" => "Value 1",
        "field2" => "100",
        "field3" => "true"
      }

      result = SchemaHelpers.struct_from_params(RootSchema, params)

      assert %RootSchema{
               field1: "Value 1",
               field2: 100,
               field3: true,
               embedded_item: nil,
               list_items: []
             } = result
    end

    test "correctly casts a single embedded schema (embeds_one)" do
      params = %{
        "field1" => "Root Value",
        "embedded_item" => %{
          "sub_field1" => "Sub Value 1",
          "sub_field2" => "Sub Value 2"
        }
      }

      result = SchemaHelpers.struct_from_params(RootSchema, params)

      assert %RootSchema{field1: "Root Value", embedded_item: item} = result
      assert %EmbeddedSchema{sub_field1: "Sub Value 1", sub_field2: "Sub Value 2"} = item
    end

    test "correctly casts a list of embedded schemas (embeds_many)" do
      params = %{
        "field1" => "Root With List",
        "list_items" => [
          %{"list_field1" => "Item A"},
          %{"list_field1" => "Item B", "list_field2" => "custom_value"}
        ]
      }

      result = SchemaHelpers.struct_from_params(RootSchema, params)

      assert %RootSchema{field1: "Root With List", list_items: items} = result

      assert [
               %ListItemSchema{list_field1: "Item A", list_field2: "default_value"},
               %ListItemSchema{list_field1: "Item B", list_field2: "custom_value"}
             ] = items
    end

    test "handles deeply nested embedded schemas" do
      params = %{
        "field1" => "Deep Root",
        "embedded_item" => %{
          "sub_field1" => "Sub Level 1",
          "nested_item" => %{
            "nested_field" => "Deepest Value"
          }
        }
      }

      result = SchemaHelpers.struct_from_params(RootSchema, params)

      assert %RootSchema{embedded_item: %EmbeddedSchema{nested_item: nested}} = result
      assert %NestedEmbedSchema{nested_field: "Deepest Value"} = nested
    end

    test "ignores extra parameters not defined in the schema" do
      params = %{
        "field1" => "Extra Fields",
        "field2" => "40",
        "extra_field" => "should be ignored",
        "embedded_item" => %{
          "sub_field1" => "Sub with extra",
          "extra_sub_field" => "also ignored"
        }
      }

      result = SchemaHelpers.struct_from_params(RootSchema, params)

      assert %RootSchema{field1: "Extra Fields", field2: 40, embedded_item: item} = result
      assert %EmbeddedSchema{sub_field1: "Sub with extra", sub_field2: nil} = item
      refute Map.has_key?(result, :extra_field)
      refute Map.has_key?(item, :extra_sub_field)
    end

    test "handles empty params map" do
      params = %{}
      result = SchemaHelpers.struct_from_params(RootSchema, params)

      assert %RootSchema{
               field1: nil,
               field2: nil,
               field3: false,
               embedded_item: nil,
               list_items: []
             } = result
    end

    test "handles empty list for embeds_many" do
      params = %{"field1" => "No List Items", "list_items" => []}
      result = SchemaHelpers.struct_from_params(RootSchema, params)

      assert %RootSchema{field1: "No List Items", list_items: []} = result
    end

    test "handles empty map for embeds_one" do
      params = %{"field1" => "Empty Embedded", "embedded_item" => %{}}
      result = SchemaHelpers.struct_from_params(RootSchema, params)

      assert %RootSchema{field1: "Empty Embedded", embedded_item: item} = result
      assert %EmbeddedSchema{sub_field1: nil, sub_field2: nil} = item
    end
  end
end
