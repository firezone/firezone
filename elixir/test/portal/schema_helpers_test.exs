defmodule Portal.SchemaHelpersTest do
  use ExUnit.Case, async: true

  alias Portal.SchemaHelpers

  # --- Test Schemas ---

  defmodule NestedEmbedSchema do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :nested_field, :string
    end
  end

  defmodule EmbeddedSchema do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :sub_field1, :string
      field :sub_field2, :string
      embeds_one :nested_item, NestedEmbedSchema
    end
  end

  defmodule ListItemSchema do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :list_field1, :string
      field :list_field2, :string, default: "default_value"
    end
  end

  defmodule DateTimeSchema do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field :datetime_field, :utc_datetime_usec
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

    test "correctly casts ISO 8601 datetime string" do
      params = %{
        "datetime_field" => "2023-12-25T10:30:45Z"
      }

      result = SchemaHelpers.struct_from_params(DateTimeSchema, params)

      assert %DateTimeSchema{datetime_field: datetime} = result
      assert %DateTime{} = datetime
      assert datetime.year == 2023
      assert datetime.month == 12
      assert datetime.day == 25
      assert datetime.hour == 10
      assert datetime.minute == 30
      assert datetime.second == 45
      assert datetime.time_zone == "Etc/UTC"
    end

    test "correctly casts ISO 8601 datetime string with microseconds" do
      params = %{
        "datetime_field" => "2023-12-25T10:30:45.123456Z"
      }

      result = SchemaHelpers.struct_from_params(DateTimeSchema, params)

      assert %DateTimeSchema{datetime_field: datetime} = result
      assert %DateTime{} = datetime
      assert datetime.microsecond == {123_456, 6}
    end

    test "correctly casts ISO 8601 datetime string with timezone offset" do
      params = %{
        "datetime_field" => "2023-12-25T10:30:45+02:00"
      }

      result = SchemaHelpers.struct_from_params(DateTimeSchema, params)

      assert %DateTimeSchema{datetime_field: datetime} = result
      assert %DateTime{} = datetime
      # Should be converted to UTC
      assert datetime.time_zone == "Etc/UTC"
      # Should be adjusted for timezone (10:30 +02:00 = 08:30 UTC)
      assert datetime.hour == 8
      assert datetime.minute == 30
    end

    test "correctly casts ISO 8601 datetime string with negative timezone offset" do
      params = %{
        "datetime_field" => "2023-12-25T10:30:45-05:00"
      }

      result = SchemaHelpers.struct_from_params(DateTimeSchema, params)

      assert %DateTimeSchema{datetime_field: datetime} = result
      assert %DateTime{} = datetime
      # Should be converted to UTC
      assert datetime.time_zone == "Etc/UTC"
      # Should be adjusted for timezone (10:30 -05:00 = 15:30 UTC)
      assert datetime.hour == 15
      assert datetime.minute == 30
    end

    test "handles nil datetime field" do
      params = %{
        "datetime_field" => nil
      }

      result = SchemaHelpers.struct_from_params(DateTimeSchema, params)

      assert %DateTimeSchema{datetime_field: nil} = result
    end

    test "handles missing datetime field" do
      params = %{}

      result = SchemaHelpers.struct_from_params(DateTimeSchema, params)

      assert %DateTimeSchema{datetime_field: nil} = result
    end

    test "handles DateTime struct input" do
      datetime = DateTime.utc_now()

      params = %{
        "datetime_field" => datetime
      }

      result = SchemaHelpers.struct_from_params(DateTimeSchema, params)

      assert %DateTimeSchema{datetime_field: ^datetime} = result
    end

    test "handles invalid datetime string gracefully" do
      params = %{
        "datetime_field" => "invalid-datetime"
      }

      result = SchemaHelpers.struct_from_params(DateTimeSchema, params)

      # Ecto casting should handle invalid datetime strings by setting to nil
      # or keeping the original value depending on changeset validation
      assert %DateTimeSchema{} = result
    end

    test "correctly casts datetime string without 'Z' suffix" do
      params = %{
        "datetime_field" => "2023-12-25T10:30:45"
      }

      result = SchemaHelpers.struct_from_params(DateTimeSchema, params)

      assert %DateTimeSchema{datetime_field: datetime} = result
      # Should still parse as UTC when no timezone is specified
      assert %DateTime{} = datetime
      assert datetime.year == 2023
      assert datetime.month == 12
      assert datetime.day == 25
    end

    test "correctly casts NaiveDateTime to DateTime" do
      naive_datetime = ~N[2023-12-25 10:30:45]

      params = %{
        "datetime_field" => naive_datetime
      }

      result = SchemaHelpers.struct_from_params(DateTimeSchema, params)

      assert %DateTimeSchema{datetime_field: datetime} = result
      assert %DateTime{} = datetime
      assert datetime.year == 2023
      assert datetime.month == 12
      assert datetime.day == 25
      assert datetime.hour == 10
      assert datetime.minute == 30
      assert datetime.second == 45
      assert datetime.time_zone == "Etc/UTC"
    end
  end
end
