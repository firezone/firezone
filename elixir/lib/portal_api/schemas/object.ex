defmodule PortalAPI.Schemas.Object do
  @moduledoc """
  Wraps `OpenApiSpex.schema/1` for response objects whose JSON view emits every
  declared key on every call.

  Two things drift by hand and are derived here instead:

    * `required` — computed from the declared properties, so it can never fall
      behind as fields are added. Nullability stays an explicit per-property
      concern (`nullable: true`); presence and null-ness are separate axes.

    * `field_names/0` — the property list, exposed so the JSON view can build
      its payload from the same source rather than a parallel map literal.

  Properties the view may omit are declared with `optional:`, which drops them
  from `required` while keeping them under the same exposure checks:

      object(%{...}, optional: [:ip_stack, :site_id])
  """

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

  defmacro __using__(_opts) do
    quote do
      require OpenApiSpex
      import PortalAPI.Schemas.Object, only: [object: 1, object: 2]
      alias OpenApiSpex.Schema
    end
  end

  defmacro object(body, opts \\ []) do
    quote do
      schema_body = unquote(body)
      opts = unquote(opts)
      field_names = schema_body.properties |> Map.keys() |> Enum.sort()
      optional = opts |> Keyword.get(:optional, []) |> Enum.sort()

      case optional -- field_names do
        [] -> :ok
        stale -> raise CompileError, description: "#{inspect(__MODULE__)} marks unknown properties optional: #{inspect(stale)}"
      end

      @field_names field_names
      @optional_field_names optional

      OpenApiSpex.schema(Map.put(schema_body, :required, field_names -- optional))

      @doc "Property names declared by this schema, in sorted order."
      @spec field_names() :: [atom()]
      def field_names, do: @field_names

      @doc "Properties that may be absent from the payload."
      @spec optional_field_names() :: [atom()]
      def optional_field_names, do: @optional_field_names
    end
  end
end
