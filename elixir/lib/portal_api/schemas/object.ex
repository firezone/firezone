defmodule PortalAPI.Schemas.Object do
  @moduledoc """
  Helpers for response schemas whose payload is emitted in full.

  These are ordinary functions called from a schema's module body, so the
  schemas stay plain `OpenApiSpex.schema/1` declarations that tooling can
  follow.
  """

  @doc """
  Fills in `required` from the schema's declared properties.

      OpenApiSpex.schema(Object.with_required(%{
        title: "Site",
        type: :object,
        properties: %{...}
      }))

  A JSON view emits every property it declares, so `required` is a function of
  `properties` rather than a second list to keep in step. Properties the view
  may omit are named with `optional:` and left out of `required`:

      Object.with_required(%{...}, optional: [:ip_stack, :site_id])
  """
  @spec with_required(map(), keyword()) :: map()
  def with_required(schema, opts \\ []) when is_map(schema) do
    properties = Map.fetch!(schema, :properties)
    optional = Keyword.get(opts, :optional, [])

    case optional -- Map.keys(properties) do
      [] -> :ok
      stale -> raise ArgumentError, "optional names unknown properties: #{inspect(stale)}"
    end

    Map.put(schema, :required, Enum.sort(Map.keys(properties) -- optional))
  end

  @doc """
  Asserts that every field of `struct_module` is either exposed or internal.

  For schemas that derive their properties from the Ecto schema rather than
  listing them by hand. Without this, a newly added column is published
  automatically; with it, the build fails until the column is classified.
  """
  @spec assert_classified!(module(), [atom()], [atom()]) :: :ok
  def assert_classified!(struct_module, exposed, internal) do
    known = struct_module.__schema__(:fields) ++ struct_module.__schema__(:virtual_fields)

    case (known -- exposed) -- internal do
      [] ->
        :ok

      unclassified ->
        raise CompileError,
          description: """
          #{inspect(struct_module)} has fields that are neither exposed nor internal: \
          #{inspect(Enum.sort(unclassified))}

          Add each to @exposed (published by the API) or @internal (withheld). New
          columns are not exposed by default.\
          """
    end
  end
end
