defmodule PortalAPI.JSON do
  @moduledoc """
  Builds the JSON the REST API sends: one struct or a page of structs, encoded
  through `PortalAPI.JSON.Encoder` and wrapped in the `data` envelope.

      json(conn, JSON.encode(site))
      json(conn, JSON.encode(sites, metadata))
      json(conn, JSON.encode(account, extra: %{limits: limits}))

  The schema is found by convention from the struct: `Portal.Entra.Directory`
  is documented by `PortalAPI.Schemas.EntraDirectory.Schema`. A struct with
  more than one API shape, or a page of mixed structs, names it with `schema:`,
  a module or a function of the struct. `extra:` adds values the request
  produced and the struct does not carry.
  """

  alias PortalAPI.Pagination

  @spec encode(struct(), keyword()) :: %{data: map()}
  @spec encode([struct()], Portal.Repo.Paginator.Metadata.t()) :: %{data: [map()], metadata: map()}
  def encode(struct, opts \\ [])

  def encode(struct, opts) when is_struct(struct) and is_list(opts) do
    schema = Keyword.get(opts, :schema)
    extra = Keyword.get(opts, :extra, %{})
    %{data: struct |> encode_with(schema) |> Map.merge(extra)}
  end

  def encode(structs, metadata) when is_list(structs), do: encode(structs, metadata, [])

  @spec encode([struct()], Portal.Repo.Paginator.Metadata.t(), keyword()) ::
          %{data: [map()], metadata: map()}
  def encode(structs, metadata, opts) when is_list(structs) do
    schema = Keyword.get(opts, :schema)

    %{
      data: Enum.map(structs, &encode_with(&1, schema)),
      metadata: Pagination.metadata(metadata)
    }
  end

  defp encode_with(struct, nil), do: encode_with(struct, schema_for(struct))
  defp encode_with(struct, fun) when is_function(fun, 1), do: encode_with(struct, fun.(struct))
  defp encode_with(struct, schema), do: PortalAPI.JSON.Encoder.encode(struct(schema), struct)

  defp schema_for(%struct_module{}) do
    ["Portal" | parts] = Module.split(struct_module)
    schema = Module.concat([PortalAPI.Schemas, Enum.join(parts), Schema])

    if Code.ensure_loaded?(schema) and function_exported?(schema, :schema, 0) do
      schema
    else
      raise ArgumentError,
            "#{inspect(struct_module)} has no schema at #{inspect(schema)}; pass schema: explicitly"
    end
  end
end
