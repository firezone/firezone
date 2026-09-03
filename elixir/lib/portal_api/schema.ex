defmodule PortalAPI.Schema do
  @moduledoc """
  What a response schema module declares about the struct it documents.

  The OpenAPI properties are the fields the API exposes. Everything else on the
  struct is either listed as `internal/0` or is marked `redact: true` on the
  Ecto schema, so a new column reaches the API only once someone decides it
  should. `PortalAPI.Encoder` reads each documented property from the struct
  through `value/2`, which a schema overrides for renamed or derived fields.
  """

  @doc "The Ecto struct this schema documents."
  @callback struct_module() :: module()

  @doc "Struct fields deliberately withheld from the API."
  @callback internal() :: [atom()]

  @doc "Properties that are not struct fields: derived in `value/2` or passed as extras."
  @callback computed() :: [atom()]

  @doc "Properties read from a struct field of another name, as `property: field`."
  @callback aliases() :: keyword(atom())

  @doc "Properties the payload omits when their value is nil."
  @callback optional() :: [atom()]

  @doc "The value of `field` for `struct`. Defaults to the struct field of the same name."
  @callback value(field :: atom(), struct :: struct()) :: term()

  @optional_callbacks internal: 0, computed: 0, aliases: 0, optional: 0, value: 2

  @doc """
  The schema module a struct renders with by convention: `Portal.Entra.Directory`
  renders with `PortalAPI.Schemas.EntraDirectory.Schema`. Structs with more
  than one shape, like `Portal.Device`, name the schema explicitly instead.
  """
  @spec for_struct(struct()) :: module()
  def for_struct(%struct_module{}) do
    ["Portal" | parts] = Module.split(struct_module)
    schema = Module.concat([PortalAPI.Schemas, Enum.join(parts), Schema])

    if implemented?(schema) and schema.struct_module() == struct_module do
      schema
    else
      raise ArgumentError,
            "#{inspect(struct_module)} has no schema at #{inspect(schema)}; " <>
              "pass the schema module explicitly with the :schema option"
    end
  end

  @doc "Whether `module` is a response schema for a struct."
  @spec implemented?(module()) :: boolean()
  def implemented?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :struct_module, 0)
  end

  @doc "Every response schema module in the API."
  @spec all() :: [module()]
  def all do
    {:ok, modules} = :application.get_key(:portal, :modules)

    Enum.filter(modules, fn module ->
      String.starts_with?(Atom.to_string(module), "Elixir.PortalAPI.Schemas.") and
        implemented?(module)
    end)
  end

  @doc false
  def internal(schema), do: callback(schema, :internal, [])

  @doc false
  def computed(schema), do: callback(schema, :computed, [])

  @doc false
  def aliases(schema), do: callback(schema, :aliases, [])

  @doc false
  def optional(schema), do: callback(schema, :optional, [])

  @doc false
  def value(schema, field, struct) do
    cond do
      source = Keyword.get(aliases(schema), field) -> Map.fetch!(struct, source)
      function_exported?(schema, :value, 2) -> schema.value(field, struct)
      true -> Map.fetch!(struct, field)
    end
  end

  defp callback(schema, name, default) do
    if function_exported?(schema, name, 0), do: apply(schema, name, []), else: default
  end
end
