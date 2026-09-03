defmodule PortalAPI.Render do
  @moduledoc """
  Sends a struct, or a page of structs, as the JSON the REST API documents.

  The schema comes from `PortalAPI.Schema.for_struct/1` unless `:schema` is
  given. Any other option is an extra value merged into the payload, for the
  few fields that come from the request rather than the struct, such as a
  token secret shown once on creation.

      Render.one(conn, site)
      Render.one(conn, gateway, schema: PortalAPI.Schemas.Gateway.Schema, token: secret)
      Render.list(conn, sites, metadata)
  """

  alias PortalAPI.Encoder
  alias PortalAPI.Pagination
  alias PortalAPI.Schema

  @spec one(Plug.Conn.t(), struct(), keyword()) :: Plug.Conn.t()
  def one(conn, struct, opts \\ []) do
    Phoenix.Controller.json(conn, %{data: data(struct, opts)})
  end

  @spec list(Plug.Conn.t(), [struct()], Portal.Repo.Paginator.Metadata.t(), keyword()) ::
          Plug.Conn.t()
  def list(conn, structs, metadata, opts \\ []) do
    Phoenix.Controller.json(conn, %{
      data: Enum.map(structs, &data(&1, opts)),
      metadata: Pagination.metadata(metadata)
    })
  end

  @doc "The payload for one struct, for callers that are not sending a response."
  @spec data(struct(), keyword()) :: map()
  def data(struct, opts \\ []) do
    {schema, extras} = Keyword.pop(opts, :schema)
    Encoder.encode(schema(schema, struct), struct, Map.new(extras))
  end

  defp schema(nil, struct), do: Schema.for_struct(struct)
  defp schema(fun, struct) when is_function(fun, 1), do: fun.(struct)
  defp schema(module, _struct) when is_atom(module), do: module
end
