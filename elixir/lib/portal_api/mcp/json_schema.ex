defmodule PortalAPI.MCP.JSONSchema do
  @moduledoc """
  Converts the OpenAPI 3.0 schemas behind `openapi.json` into the JSON Schema
  2020-12 dialect that MCP tool definitions use.

  References are inlined rather than emitted as `$ref`. MCP clients are only
  required to resolve local references, and an inlined schema is the shape
  models handle most reliably. The spec's schemas are shallow enough that the
  duplication costs little.
  """

  alias OpenApiSpex.Reference
  alias OpenApiSpex.Schema

  @max_depth 12

  @doc """
  Converts one OpenAPI schema into a JSON Schema map with string keys.

  `schemas` is the spec's `components.schemas` map, used to inline references.
  """
  def convert(schema, schemas) do
    convert(schema, schemas, 0)
  end

  @doc """
  Builds the object schema for a tool from an operation's parameters and
  request body.

  Path and query parameters become top-level properties. A request body object
  contributes its own properties at the same level, which keeps arguments flat
  for the model. Bodies in this API are single-key wrappers (`{"resource":
  {...}}`), so the merge stays shallow and readable.
  """
  def build_input_schema(parameters, body_schema, schemas) do
    {param_properties, param_required} = convert_parameters(parameters, schemas)
    {body_properties, body_required} = convert_body(body_schema, schemas)

    case MapSet.intersection(
           MapSet.new(Map.keys(param_properties)),
           MapSet.new(Map.keys(body_properties))
         )
         |> MapSet.to_list() do
      [] ->
        %{
          "type" => "object",
          "properties" => Map.merge(param_properties, body_properties),
          "required" => Enum.uniq(param_required ++ body_required),
          "additionalProperties" => false
        }

      collisions ->
        raise ArgumentError,
              "request body properties collide with parameter names: #{Enum.join(collisions, ", ")}"
    end
  end

  defp convert_parameters(parameters, schemas) do
    Enum.reduce(parameters, {%{}, []}, fn parameter, {properties, required} ->
      name = to_string(parameter.name)
      converted = convert(parameter.schema, schemas, 0)

      converted =
        case parameter.description do
          nil -> converted
          description -> Map.put_new(converted, "description", description)
        end

      {Map.put(properties, name, converted),
       if parameter.required do
         [name | required]
       else
         required
       end}
    end)
  end

  defp convert_body(nil, _schemas), do: {%{}, []}

  defp convert_body(body_schema, schemas) do
    case convert(body_schema, schemas, 0) do
      %{"properties" => properties} = converted ->
        {properties, Map.get(converted, "required", [])}

      _other ->
        {%{}, []}
    end
  end

  defp convert(_schema, _schemas, depth) when depth > @max_depth do
    %{"type" => "object"}
  end

  defp convert(%Reference{"$ref": "#/components/schemas/" <> name}, schemas, depth) do
    case Map.fetch(schemas, name) do
      {:ok, schema} -> convert(schema, schemas, depth + 1)
      :error -> %{}
    end
  end

  defp convert(%Schema{} = schema, schemas, depth) do
    %{}
    |> put_type(schema)
    |> put_description(schema)
    |> put_enum(schema)
    |> put_format(schema)
    |> put_properties(schema, schemas, depth)
    |> put_items(schema, schemas, depth)
    |> put_composition(schema, schemas, depth)
    |> put_bounds(schema)
    |> put_example(schema)
  end

  defp convert(schema, _schemas, _depth) when is_map(schema) do
    schema
  end

  defp convert(_schema, _schemas, _depth), do: %{}

  defp put_type(converted, %Schema{type: nil}), do: converted

  defp put_type(converted, %Schema{type: type, nullable: true}) do
    Map.put(converted, "type", [to_string(type), "null"])
  end

  defp put_type(converted, %Schema{type: type}) do
    Map.put(converted, "type", to_string(type))
  end

  defp put_description(converted, %Schema{description: nil}), do: converted

  defp put_description(converted, %Schema{description: description}) do
    Map.put(converted, "description", description)
  end

  defp put_enum(converted, %Schema{enum: nil}), do: converted

  defp put_enum(converted, %Schema{enum: values}) do
    Map.put(converted, "enum", Enum.map(values, &enum_value/1))
  end

  defp put_format(converted, %Schema{format: nil}), do: converted

  defp put_format(converted, %Schema{format: format}) do
    Map.put(converted, "format", to_string(format))
  end

  defp put_properties(converted, %Schema{properties: nil}, _schemas, _depth), do: converted

  defp put_properties(converted, %Schema{} = schema, schemas, depth) do
    properties =
      Map.new(schema.properties, fn {name, property} ->
        {to_string(name), convert(property, schemas, depth + 1)}
      end)

    converted
    |> Map.put("properties", properties)
    |> put_required(schema)
  end

  defp put_required(converted, %Schema{required: nil}), do: converted
  defp put_required(converted, %Schema{required: []}), do: converted

  defp put_required(converted, %Schema{required: required}) do
    Map.put(converted, "required", Enum.map(required, &to_string/1))
  end

  defp put_items(converted, %Schema{items: nil}, _schemas, _depth), do: converted

  defp put_items(converted, %Schema{items: items}, schemas, depth) do
    Map.put(converted, "items", convert(items, schemas, depth + 1))
  end

  defp put_composition(converted, %Schema{} = schema, schemas, depth) do
    Enum.reduce([{:oneOf, "oneOf"}, {:anyOf, "anyOf"}, {:allOf, "allOf"}], converted, fn
      {key, json_key}, acc ->
        case Map.get(schema, key) do
          nil ->
            acc

          [] ->
            acc

          subschemas ->
            Map.put(acc, json_key, Enum.map(subschemas, &convert(&1, schemas, depth + 1)))
        end
    end)
  end

  defp put_bounds(converted, %Schema{} = schema) do
    Enum.reduce(
      [
        {:minimum, "minimum"},
        {:maximum, "maximum"},
        {:minLength, "minLength"},
        {:maxLength, "maxLength"},
        {:minItems, "minItems"},
        {:maxItems, "maxItems"},
        {:pattern, "pattern"}
      ],
      converted,
      fn {key, json_key}, acc ->
        case Map.get(schema, key) do
          nil -> acc
          value -> Map.put(acc, json_key, bound_value(value))
        end
      end
    )
  end

  defp put_example(converted, %Schema{example: nil}), do: converted

  defp put_example(converted, %Schema{example: example}) do
    Map.put(converted, "examples", [example])
  end

  defp bound_value(%Regex{} = regex), do: Regex.source(regex)
  defp bound_value(value), do: value

  defp enum_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp enum_value(value), do: value
end
