defprotocol PortalAPI.JSON.Encoder do
  @moduledoc """
  Builds the map the REST API sends for a struct, as documented by an OpenAPI
  schema.

  Derived in the schema module, naming the Ecto struct it documents. The
  schema's properties are the fields the API exposes: a struct field that is
  not a property never leaves the portal, and neither does a field marked
  `redact: true`. A property that is not required is omitted when nil.

      defmodule Schema do
        @derive {PortalAPI.JSON.Encoder, for: Portal.Site}
        OpenApiSpex.schema(%{title: "Site", properties: %{...}})
      end

  Properties the struct does not carry under the same name come from `map/2`
  in the same module, which receives the struct and the map built so far and
  returns the keys to add:

      def map(%Portal.Device{} = device, _map), do: %{online: device.online?}
  """

  @doc "The API representation of `struct` as documented by the schema of `schema`."
  @spec encode(t, struct()) :: map()
  def encode(schema, struct)

  defmacro __deriving__(module, opts) do
    struct_module = Keyword.fetch!(opts, :for)

    quote do
      defimpl PortalAPI.JSON.Encoder, for: unquote(module) do
        def encode(_schema, %unquote(struct_module){} = struct) do
          PortalAPI.JSON.Encoder.Derived.encode(unquote(module), unquote(struct_module), struct)
        end
      end
    end
  end
end

defmodule PortalAPI.JSON.Encoder.Derived do
  @moduledoc false

  @doc false
  def encode(schema, struct_module, struct) do
    %{properties: properties, required: required} = schema.schema()
    documented = Map.keys(properties)

    fields =
      (struct_module.__schema__(:fields) ++ struct_module.__schema__(:virtual_fields)) --
        struct_module.__schema__(:redact_fields)

    base = Map.take(struct, documented -- (documented -- fields))

    encoded =
      if function_exported?(schema, :map, 2) do
        Map.merge(base, schema.map(struct, base))
      else
        base
      end

    Map.reject(encoded, fn {key, value} -> is_nil(value) and key not in List.wrap(required) end)
  end
end
