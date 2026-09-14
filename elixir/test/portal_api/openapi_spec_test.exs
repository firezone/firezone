defmodule PortalAPI.OpenAPISpecTest do
  use ExUnit.Case, async: true

  alias OpenApiSpex.Reference

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

  defp example_error(example, title, spec) do
    ref = %Reference{"$ref": "#/components/schemas/#{title}"}
    OpenApiSpex.TestAssertions.assert_raw_schema(example, ref, spec)
    nil
  rescue
    error in ExUnit.AssertionError -> error.message
  end
end
