defmodule PortalAPI.OpenAPISpecTest do
  use ExUnit.Case, async: true

  alias OpenApiSpex.Example
  alias OpenApiSpex.MediaType
  alias OpenApiSpex.Operation
  alias OpenApiSpex.Reference
  alias OpenApiSpex.RequestBody
  alias OpenApiSpex.Response

  setup_all do
    %{spec: PortalAPI.OpenAPIAssertions.strict_spec()}
  end

  test "no two schema modules share a title" do
    # components.schemas is keyed by title, so a duplicate silently replaces
    # the other module and every $ref to that title resolves to whichever won.
    {:ok, modules} = :application.get_key(:portal, :modules)

    duplicates =
      modules
      |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir.PortalAPI.Schemas."))
      |> Enum.filter(&function_exported?(&1, :schema, 0))
      |> Enum.group_by(& &1.schema().title)
      |> Enum.reject(fn {title, mods} -> is_nil(title) or length(mods) == 1 end)

    assert duplicates == [],
           "These OpenAPI titles are declared by more than one schema module:\n" <>
             Enum.map_join(duplicates, "\n", fn {title, mods} -> "  #{title}: #{inspect(mods)}" end)
  end

  test "every schema example conforms to its schema", %{spec: spec} do
    failures =
      for {title, %{example: example}} <- spec.components.schemas,
          not is_nil(example),
          message = example_error(example, title, spec),
          do: "#{title}: #{message}"

    assert failures == [], Enum.join(failures, "\n\n")
  end

  test "every request and response example conforms to its schema", %{spec: spec} do
    failures =
      for {path, path_item} <- spec.paths,
          {method, %Operation{} = operation} <- Map.from_struct(path_item),
          {where, content} <- operation_content(operation),
          {media_type, %MediaType{schema: schema} = media} <- content,
          {name, value} <- media_examples(media),
          message = media_example_error(value, schema, spec),
          do: "#{method} #{path} #{where} #{media_type} #{name}: #{message}"

    assert failures == [], Enum.join(failures, "\n\n")
  end

  defp example_error(example, title, spec) do
    ref = %Reference{"$ref": "#/components/schemas/#{title}"}
    media_example_error(example, ref, spec)
  end

  defp media_example_error(example, schema, spec) do
    OpenApiSpex.TestAssertions.assert_raw_schema(example, schema, spec)
    nil
  rescue
    error in ExUnit.AssertionError -> error.message
  end

  defp operation_content(%Operation{requestBody: request_body, responses: responses}) do
    request =
      case request_body do
        %RequestBody{content: %{} = content} -> [{"request", content}]
        _ -> []
      end

    response =
      for {status, %Response{content: %{} = content}} <- responses || %{},
          do: {"response #{status}", content}

    request ++ response
  end

  defp media_examples(%MediaType{example: nil, examples: examples}), do: named_examples(examples)

  defp media_examples(%MediaType{example: example, examples: examples}),
    do: [{"example", example} | named_examples(examples)]

  defp named_examples(examples) do
    for {name, %Example{value: value}} <- examples || %{}, do: {name, value}
  end
end
