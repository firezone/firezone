defmodule PortalAPI.JSON do
  @moduledoc """
  Compile-time contract between an Ecto schema, its OpenAPI schema, and the JSON
  view that renders it.

  A view declares the struct it renders, the OpenAPI schema describing the
  payload, and — exhaustively — which of the struct's fields are deliberately
  withheld:

      use PortalAPI.JSON,
        struct: Portal.Iru.PostureProvider,
        schema: PortalAPI.Schemas.IruPostureProvider.Schema,
        computed: [:type, :name],
        internal: [:api_token, :error_email_count]

  Three properties are enforced at compile time:

    * every field the OpenAPI schema declares exists on the struct, so a rename
      cannot leave the spec describing a field that is no longer emitted;

    * every struct field is classified as either exposed or `:internal`, so a
      newly added column fails the build until someone decides which it is;

    * `:computed` and `:internal` name only fields that are real, so stale
      entries cannot quietly accumulate.

  Exposure is therefore an allowlist: a field reaches the API only by being
  declared in the OpenAPI schema, and the build fails rather than defaulting to
  exposure.
  """

  @doc """
  Asserts that a view's declared exposure matches the struct it renders.

  Called from the view's module body, so a mismatch fails the build:

      PortalAPI.JSON.verify!(__MODULE__, Portal.Site, PortalAPI.Schemas.Site.Schema,
        internal: [:account_id, :inserted_at, :updated_at])

  Options:

    * `:internal` - fields deliberately withheld from the API.
    * `:computed` - declared properties the view supplies itself rather than
      reading from the struct.

  Three properties are enforced:

    * every property the schema declares exists on the struct, so a rename
      cannot leave the spec describing a field that is no longer emitted;

    * every struct field is classified as exposed or `:internal`, so a newly
      added column fails the build until someone decides which it is;

    * `:computed` and `:internal` name only fields that are real, so stale
      entries cannot quietly accumulate.

  Exposure is therefore an allowlist: a field reaches the API only by being
  declared in the schema, and the build fails rather than defaulting to
  exposure.
  """
  @spec verify!(module(), module(), module(), keyword()) :: :ok
  def verify!(view, struct_module, schema_module, opts \\ []) do
    Code.ensure_compiled!(struct_module)
    Code.ensure_compiled!(schema_module)

    computed = MapSet.new(Keyword.get(opts, :computed, []))
    internal = MapSet.new(Keyword.get(opts, :internal, []))

    known =
      MapSet.new(struct_module.__schema__(:fields) ++ struct_module.__schema__(:virtual_fields))

    declared = MapSet.new(declared_fields(schema_module))
    exposed = MapSet.difference(declared, computed)

    bail!(view, "declares fields that #{inspect(struct_module)} does not have",
      MapSet.difference(exposed, known),
      "Remove them from #{inspect(schema_module)}, or list them as :computed if the view supplies them.")

    bail!(view, "lists :computed keys the OpenAPI schema does not declare",
      MapSet.difference(computed, declared),
      "A computed value still has to be a declared property of #{inspect(schema_module)}.")

    bail!(view, "lists :internal fields that #{inspect(struct_module)} does not have",
      MapSet.difference(internal, known),
      "Remove the stale entries from :internal.")

    bail!(view, "exposes fields that are also marked :internal",
      MapSet.intersection(declared, internal),
      "A field is either in the OpenAPI schema or :internal, not both.")

    bail!(view, "does not classify every field of #{inspect(struct_module)}",
      known |> MapSet.difference(declared) |> MapSet.difference(internal),
      """
      Each field must be either declared in #{inspect(schema_module)} (exposed to
      the API) or listed as :internal (deliberately withheld). New fields are not
      exposed by default - this is the allowlist working.\
      """)

    :ok
  end

  defp bail!(view, problem, offenders, hint) do
    if MapSet.size(offenders) > 0 do
      raise CompileError,
        description: """
        #{inspect(view)} #{problem}: #{inspect(Enum.sort(offenders))}

        #{hint}\
        """
    end

    :ok
  end

  defp declared_fields(schema_module), do: schema_module.schema().properties |> Map.keys()

  @doc """
  Builds a payload containing exactly the OpenAPI schema's declared fields.

  Values are taken from `source` by key; `computed` supplies fields the struct
  does not carry. Both are narrowed to the declared fields, so a stray computed
  key cannot widen the payload beyond the schema. Rendering stays total: a key
  the schema does not declare is dropped rather than raised on, since this runs
  on every response. Declaring one is caught at compile time instead, and a
  misspelled key still raises here because the field it was meant to supply
  goes missing.
  """
  @spec render(struct(), module(), map()) :: map()
  def render(source, schema_module, computed \\ %{}) do
    schema = schema_module.schema()
    fields = Map.keys(schema.properties)
    optional = fields -- List.wrap(schema.required)

    payload = source |> Map.take(fields) |> Map.merge(Map.take(computed, fields))

    case (fields -- Map.keys(payload)) -- optional do
      [] ->
        payload

      missing ->
        raise ArgumentError,
              "#{inspect(schema_module)} declares fields the payload does not provide: " <>
                "#{inspect(missing)}"
    end
  end

  @doc """
  Drops keys whose value is nil.

  For payloads that omit a field entirely rather than sending null. The keys
  must be declared `optional:` on the schema.
  """
  @spec omit_nils(map(), [atom()]) :: map()
  def omit_nils(payload, keys) do
    Enum.reduce(keys, payload, fn key, acc ->
      if Map.get(acc, key) == nil, do: Map.delete(acc, key), else: acc
    end)
  end
end
