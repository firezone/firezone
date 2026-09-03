defmodule PortalAPI.OpenAPIAssertions do
  @moduledoc """
  Checks a rendered API response against the OpenAPI operation that served it.

  The spec is cast strictly: every object with declared properties rejects
  keys it does not document, so an undocumented field fails the test just like
  a wrong type, a missing required field, or a null where none is allowed.
  """
  import ExUnit.Assertions

  alias OpenApiSpex.Reference
  alias OpenApiSpex.Schema

  @doc """
  Asserts that `body` matches the response schema the operation behind `conn`
  declares for `conn.status`.

  Routes without an OpenAPI operation, such as third-party webhooks, are not
  part of the published API and are skipped.
  """
  def assert_response_conforms(conn, body) do
    with %{plug: controller, plug_opts: action} <- route(conn),
         true <- function_exported?(controller, :open_api_operation, 1) do
      operation = controller.open_api_operation(action)
      schema = response_schema(operation, conn, controller, action)

      spec = strict_spec()
      OpenApiSpex.TestAssertions.assert_raw_schema(body, close(schema, spec.components.schemas), spec)
    end

    body
  end

  @doc """
  Returns the API spec with every object that declares properties closed to
  undeclared keys.
  """
  def strict_spec do
    spec = PortalAPI.ApiSpec.spec()
    schemas = spec.components.schemas
    put_in(spec.components.schemas, Map.new(schemas, fn {k, v} -> {k, close(v, schemas)} end))
  end

  defp route(conn) do
    Phoenix.Router.route_info(PortalAPI.Router, conn.method, conn.request_path, conn.host)
  end

  defp response_schema(operation, conn, controller, action) do
    status = conn.status
    content_type = conn |> Plug.Conn.get_resp_header("content-type") |> List.first("") |> media_type()

    schema =
      case operation.responses do
        %{^status => %{content: %{^content_type => %{schema: schema}}}} -> schema
        _ -> nil
      end

    if is_nil(schema) do
      flunk(
        "#{inspect(controller)}.#{action} declares no #{conn.status} #{content_type} response " <>
          "in its OpenAPI operation, but the test received one"
      )
    end

    castable(schema)
  end

  defp media_type(header), do: header |> String.split(";") |> hd() |> String.trim()

  defp castable(module) when is_atom(module) do
    %Reference{"$ref": "#/components/schemas/#{module.schema().title}"}
  end

  defp castable(%Schema{} = schema), do: schema
  defp castable(%Reference{} = ref), do: ref

  # `allOf` is merged into one object first: closing each part separately
  # would make every part reject the keys the other parts declare.
  defp close(%Schema{allOf: [_ | _] = parts} = schema, schemas) do
    parts
    |> Enum.map(&resolve(&1, schemas))
    |> Enum.reduce(%{schema | allOf: nil}, fn part, acc ->
      %{
        acc
        | type: :object,
          properties: Map.merge(acc.properties || %{}, part.properties || %{}),
          required: (acc.required || []) ++ (part.required || [])
      }
    end)
    |> close(schemas)
  end

  defp close(%Schema{} = schema, schemas) do
    schema
    |> close_object()
    |> Map.update!(:properties, &close_map(&1, schemas))
    |> Map.update!(:items, &close(&1, schemas))
    |> Map.update!(:additionalProperties, &close(&1, schemas))
    |> Map.update!(:oneOf, &close_list(&1, schemas))
    |> Map.update!(:anyOf, &close_list(&1, schemas))
    |> Map.update!(:not, &close(&1, schemas))
  end

  defp close(other, _schemas), do: other

  defp resolve(%Reference{} = ref, schemas), do: OpenApiSpex.resolve_schema(ref, schemas)
  defp resolve(%Schema{} = schema, _schemas), do: schema

  defp close_object(%Schema{type: :object, properties: %{} = props, additionalProperties: nil} = schema)
       when map_size(props) > 0 do
    %{schema | additionalProperties: false}
  end

  defp close_object(schema), do: schema

  defp close_map(%{} = map, schemas), do: Map.new(map, fn {k, v} -> {k, close(v, schemas)} end)
  defp close_map(other, _schemas), do: other

  defp close_list(list, schemas) when is_list(list), do: Enum.map(list, &close(&1, schemas))
  defp close_list(other, _schemas), do: other
end
