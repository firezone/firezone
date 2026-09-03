defprotocol PortalAPI.JSON.Encoder do
  @moduledoc """
  Builds the map the REST API sends for a struct, as documented by an OpenAPI
  schema.

  Derived in the schema module, naming the Ecto struct it documents and the
  struct fields the API deliberately withholds. The schema's properties are
  the fields the API exposes, and the build fails if a struct field is neither
  a property, nor listed as internal, nor marked `redact: true`, so a new
  column is exposed only once someone decides it should be. A property that
  is not required is omitted when nil.

      defmodule Schema do
        @derive {PortalAPI.JSON.Encoder,
                 for: Portal.Site,
                 internal: [:account_id, :health_threshold, :managed_by, :inserted_at, :updated_at]}
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
    internal = Keyword.get(opts, :internal, [])

    properties = module |> Macro.struct_info!(__CALLER__) |> Enum.map(& &1.field)
    PortalAPI.JSON.Encoder.Derived.check!(module, struct_module, properties, internal)

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
  def check!(schema, struct_module, properties, internal) do
    fields = struct_module.__schema__(:fields) ++ struct_module.__schema__(:virtual_fields)
    redacted = struct_module.__schema__(:redact_fields)

    problems =
      [
        {"has fields that #{inspect(schema)} neither documents nor lists as internal",
         (fields -- properties) -- (internal ++ redacted)},
        {"does not have the fields #{inspect(schema)} lists as internal", internal -- fields},
        {"has fields marked redact: true that #{inspect(schema)} documents",
         properties -- (properties -- redacted)}
      ]
      |> Enum.reject(fn {_message, offenders} -> offenders == [] end)

    if problems != [] do
      raise ArgumentError,
            Enum.map_join(problems, "\n", fn {message, offenders} ->
              "#{inspect(struct_module)} #{message}: #{inspect(Enum.sort(offenders))}"
            end)
    end

    :ok
  end

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
