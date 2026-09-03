defmodule PortalAPI.Schemas.ContractTest do
  @moduledoc """
  Keeps each response schema aligned with the Ecto struct it declares.

  Every struct field must be a documented property, or listed as internal by
  the schema, so a new column reaches the API only once someone decides it
  should. Fields marked `redact: true` on the Ecto schema are internal by
  definition and must never appear as a property.
  """
  use ExUnit.Case, async: true

  alias OpenApiSpex.Schema

  for schema <- PortalAPI.Schema.all() do
    @schema schema

    describe inspect(schema) do
      test "classifies every struct field as exposed or internal" do
        struct = @schema.struct_module()
        internal = PortalAPI.Schema.internal(@schema)
        redacted = struct.__schema__(:redact_fields)

        unclassified =
          (fields(struct) -- exposed_fields(@schema)) --
            (internal ++ PortalAPI.Schema.computed(@schema) ++ redacted)

        assert unclassified == [],
               "#{inspect(struct)} has fields that are neither documented by " <>
                 "#{inspect(@schema)} nor listed as internal: #{inspect(unclassified)}"

        assert internal -- fields(struct) == [],
               "internal lists fields #{inspect(struct)} does not have: " <>
                 inspect(internal -- fields(struct))
      end

      test "documents only fields the struct has" do
        struct = @schema.struct_module()
        unknown = exposed_fields(@schema) -- fields(struct)

        assert unknown == [],
               "#{inspect(@schema)} documents fields #{inspect(struct)} does not have: " <>
                 "#{inspect(unknown)}. List them as computed if value/2 derives them."
      end

      test "never documents a redacted field" do
        struct = @schema.struct_module()
        exposed = exposed_fields(@schema)
        leaked = exposed -- (exposed -- struct.__schema__(:redact_fields))

        assert leaked == [],
               "#{inspect(@schema)} documents fields marked redact: true on " <>
                 "#{inspect(struct)}: #{inspect(leaked)}"
      end

      test "property types match the struct's Ecto types" do
        struct = @schema.struct_module()
        aliases = PortalAPI.Schema.aliases(@schema)
        computed = PortalAPI.Schema.computed(@schema)

        mismatches =
          for {property, %Schema{oneOf: nil, anyOf: nil, allOf: nil} = schema} <-
                @schema.schema().properties,
              property not in computed,
              field = Keyword.get(aliases, property, property),
              expected = expected_type(ecto_type(struct, field)),
              problem = compare(expected, schema),
              do: {property, problem}

        assert mismatches == [],
               "#{inspect(@schema)} property types disagree with #{inspect(struct)}:\n" <>
                 Enum.map_join(mismatches, "\n", fn {p, m} -> "  #{p}: #{m}" end)
      end

      test "marks every property required unless listed as optional" do
        schema = @schema.schema()
        not_required = Map.keys(schema.properties) -- List.wrap(schema.required)

        assert Enum.sort(not_required) == Enum.sort(PortalAPI.Schema.optional(@schema)),
               "#{inspect(@schema)} must list every property the payload always " <>
                 "carries as required. Not required: #{inspect(Enum.sort(not_required))}"
      end
    end
  end

  test "every response schema declares its struct" do
    assert length(PortalAPI.Schema.all()) >= 32
  end

  defp fields(struct), do: struct.__schema__(:fields) ++ struct.__schema__(:virtual_fields)

  defp exposed_fields(schema) do
    aliases = PortalAPI.Schema.aliases(schema)

    schema.schema().properties
    |> Map.keys()
    |> Kernel.--(PortalAPI.Schema.computed(schema))
    |> Enum.map(&Keyword.get(aliases, &1, &1))
  end

  defp ecto_type(struct, field) do
    struct.__schema__(:type, field) || struct.__schema__(:virtual_type, field)
  end

  defp expected_type(:binary_id), do: {:string, :uuid}
  defp expected_type(Ecto.UUID), do: {:string, :uuid}
  defp expected_type(:string), do: {:string, nil}
  defp expected_type(:boolean), do: {:boolean, nil}
  defp expected_type(:integer), do: {:integer, nil}
  defp expected_type(:float), do: {:number, nil}
  defp expected_type(:utc_datetime_usec), do: {:string, :"date-time"}
  defp expected_type(:utc_datetime), do: {:string, :"date-time"}
  defp expected_type(:map), do: {:object, nil}
  defp expected_type(:bigint), do: {:integer, nil}
  defp expected_type({:array, _}), do: {:array, nil}
  defp expected_type(Portal.Types.IP), do: {:string, nil}

  defp expected_type({:parameterized, {Ecto.Enum, %{on_load: values}}}) do
    {:enum, values |> Map.keys() |> Enum.sort()}
  end

  defp expected_type(_other), do: nil

  defp compare({:enum, values}, %Schema{type: :string, enum: enum}) when is_list(enum) do
    if Enum.sort(enum) == values do
      nil
    else
      "enum #{inspect(Enum.sort(enum))} differs from Ecto.Enum values #{inspect(values)}"
    end
  end

  defp compare({:enum, values}, %Schema{}), do: "expected a string enum of #{inspect(values)}"

  defp compare({type, format}, %Schema{type: actual, format: actual_format}) do
    cond do
      type != actual ->
        "expected type #{inspect(type)}, schema says #{inspect(actual)}"

      format && format != actual_format ->
        "expected format #{inspect(format)}, schema says #{inspect(actual_format)}"

      true ->
        nil
    end
  end
end
