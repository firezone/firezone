defmodule PortalAPI.MCP.JSONSchema do
  @moduledoc """
  Converts the OpenAPI 3.0 schemas behind `openapi.json` into the JSON Schema
  2020-12 dialect that MCP tool definitions use.

  Non-recursive references are inlined. Recursive expressions use local
  `$defs` references so clients can describe the full grammar without
  truncating nested policy postures or exponentially expanding the schema.
  """

  alias OpenApiSpex.Reference
  alias OpenApiSpex.Schema

  @doc """
  Converts one OpenAPI schema into a JSON Schema map with string keys.

  `schemas` is the spec's `components.schemas` map, used to inline references.
  """
  def convert(schema, schemas) do
    schema
    |> convert(schemas, [])
    |> put_definitions(schemas)
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
        |> put_definitions(schemas)

      collisions ->
        raise ArgumentError,
              "request body properties collide with parameter names: #{Enum.join(collisions, ", ")}"
    end
  end

  defp convert_parameters(parameters, schemas) do
    Enum.reduce(parameters, {%{}, []}, fn parameter, {properties, required} ->
      name = to_string(parameter.name)
      converted = convert(parameter.schema, schemas, [])
      converted = path_identifier_schema(converted, parameter.in, name)

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

  # Match Dispatch's pre-routing identifier checks, including operations whose
  # OpenAPI parameter omitted an explicit type. These are not optional hints.
  defp path_identifier_schema(schema, :path, "log_id") do
    Map.merge(schema, %{"type" => "string", "pattern" => "^[0-9a-fA-F]{24}$", "minLength" => 24, "maxLength" => 24})
  end

  defp path_identifier_schema(schema, :path, _name) do
    Map.merge(schema, %{"type" => "string", "format" => "uuid", "minLength" => 36, "maxLength" => 36})
  end

  defp path_identifier_schema(schema, _location, _name), do: schema

  defp convert_body(nil, _schemas), do: {%{}, []}

  defp convert_body(body_schema, schemas) do
    case convert(body_schema, schemas, []) do
      %{"properties" => properties} = converted ->
        {properties, Map.get(converted, "required", [])}

      _other ->
        {%{}, []}
    end
  end

  defp convert(%Reference{"$ref": "#/components/schemas/" <> name}, schemas, seen) do
    if name in seen do
      %{"$ref" => "#/$defs/#{name}"}
    else
      schemas |> Map.fetch!(name) |> convert(schemas, [name | seen])
    end
  end

  defp convert(%Schema{nullable: true} = schema, schemas, seen) do
    converted = convert(%{schema | nullable: false}, schemas, seen)

    if schema.type && is_nil(schema.enum) && is_nil(schema.allOf) &&
         is_nil(schema.oneOf) && is_nil(schema.anyOf) do
      Map.put(converted, "type", [to_string(schema.type), "null"])
    else
      {annotations, constraints} = Map.split(converted, ["description", "examples", "default"])
      Map.put(annotations, "anyOf", [constraints, %{"type" => "null"}])
    end
  end

  defp convert(%Schema{} = schema, schemas, seen) do
    %{}
    |> put_type(schema)
    |> put_description(schema)
    |> put_enum(schema)
    |> put_format(schema)
    |> put_properties(schema, schemas, seen)
    |> put_additional_properties(schema, schemas, seen)
    |> put_items(schema, schemas, seen)
    |> put_composition(schema, schemas, seen)
    |> put_bounds(schema)
    |> put_example(schema)
    |> put_default(schema)
  end

  defp convert(schema, _schemas, _seen) when is_map(schema) do
    schema
  end

  defp convert(_schema, _schemas, _seen), do: %{}

  defp put_type(converted, %Schema{type: nil}), do: converted

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

  defp put_properties(converted, %Schema{properties: nil}, _schemas, _seen), do: converted

  defp put_properties(converted, %Schema{} = schema, schemas, seen) do
    properties =
      Map.new(schema.properties, fn {name, property} ->
        {to_string(name), convert(property, schemas, seen)}
      end)

    converted
    |> Map.put("properties", properties)
    |> put_required(schema)
  end

  defp put_additional_properties(converted, %Schema{additionalProperties: nil}, _schemas, _seen), do: converted

  defp put_additional_properties(converted, %Schema{additionalProperties: value}, schemas, seen) do
    value = if is_boolean(value), do: value, else: convert(value, schemas, seen)
    Map.put(converted, "additionalProperties", value)
  end

  defp put_required(converted, %Schema{required: nil}), do: converted
  defp put_required(converted, %Schema{required: []}), do: converted

  defp put_required(converted, %Schema{required: required}) do
    Map.put(converted, "required", Enum.map(required, &to_string/1))
  end

  defp put_items(converted, %Schema{items: nil}, _schemas, _seen), do: converted

  defp put_items(converted, %Schema{items: items}, schemas, seen) do
    Map.put(converted, "items", convert(items, schemas, seen))
  end

  defp put_composition(converted, %Schema{} = schema, schemas, seen) do
    Enum.reduce([{:oneOf, "oneOf"}, {:anyOf, "anyOf"}, {:allOf, "allOf"}], converted, fn
      {key, json_key}, acc ->
        case Map.get(schema, key) do
          nil ->
            acc

          [] ->
            acc

          subschemas ->
            Map.put(acc, json_key, Enum.map(subschemas, &convert(&1, schemas, seen)))
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
        {:minProperties, "minProperties"},
        {:maxProperties, "maxProperties"},
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

  defp put_default(converted, %Schema{default: nil}), do: converted
  defp put_default(converted, %Schema{default: default}), do: Map.put(converted, "default", default)

  # Definitions live at the tool schema's root, including when a request body
  # is flattened into its parameters. Resolve mutual recursion as well as a
  # schema that references itself.
  defp put_definitions(converted, schemas) do
    case collect_definitions(converted, schemas, %{}) do
      definitions when map_size(definitions) == 0 -> converted
      definitions -> Map.put(converted, "$defs", definitions)
    end
  end

  defp collect_definitions(%{"$ref" => "#/$defs/" <> name}, schemas, definitions) do
    if Map.has_key?(definitions, name) do
      definitions
    else
      definition = convert(Map.fetch!(schemas, name), schemas, [name])
      collect_definitions(definition, schemas, Map.put(definitions, name, definition))
    end
  end

  defp collect_definitions(map, schemas, definitions) when is_map(map) do
    map |> Map.values() |> Enum.reduce(definitions, &collect_definitions(&1, schemas, &2))
  end

  defp collect_definitions(list, schemas, definitions) when is_list(list) do
    Enum.reduce(list, definitions, &collect_definitions(&1, schemas, &2))
  end

  defp collect_definitions(_value, _schemas, definitions), do: definitions

  defp bound_value(%Regex{} = regex), do: Regex.source(regex)
  defp bound_value(value), do: value

  defp enum_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp enum_value(value), do: value
end
