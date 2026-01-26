defmodule PortalAPI.GatewayController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias __MODULE__.Database
  alias Portal.Presence

  tags ["Gateways"]

  operation :index,
    summary: "List Gateways",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [in: :query, description: "Limit Gateways returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Gateway Response", "application/json", PortalAPI.Schemas.Gateway.ListResponse}
    ]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    list_opts =
      params
      |> Pagination.params_to_list_opts()
      |> Keyword.put(:preload, [:online?, :ipv4_address, :ipv6_address])

    list_opts =
      if site_id = params["site_id"] do
        Keyword.put(list_opts, :filter, site_id: site_id)
      else
        list_opts
      end

    with {:ok, gateways, metadata} <- Database.list_gateways(conn.assigns.subject, list_opts) do
      render(conn, :index, gateways: gateways, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation :show,
    summary: "Show Gateway",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Gateway Response", "application/json", PortalAPI.Schemas.Gateway.Response}
    ]

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, gateway} <- Database.fetch_gateway(id, conn.assigns.subject) do
      gateway = Presence.Gateways.preload_gateways_presence([gateway]) |> List.first()
      render(conn, :show, gateway: gateway)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation :delete,
    summary: "Delete a Gateway",
    parameters: [
      site_id: [
        in: :path,
        description: "Site ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ],
      id: [
        in: :path,
        description: "Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Gateway Response", "application/json", PortalAPI.Schemas.Gateway.Response}
    ]

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, gateway} <- Database.fetch_gateway(id, subject),
         {:ok, gateway} <- Database.delete_gateway(gateway, subject) do
      render(conn, :show, gateway: gateway)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Gateway
    alias Portal.Presence

    def list_gateways(subject, opts \\ []) do
      from(g in Gateway, as: :gateways)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:gateways, :asc, :inserted_at},
        {:gateways, :asc, :id}
      ]
    end

    def preloads do
      [
        online?: &Presence.Gateways.preload_gateways_presence/1
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :site_id,
          title: "Site",
          type: {:string, :uuid},
          fun: &filter_by_site_id/2
        }
      ]
    end

    defp filter_by_site_id(queryable, site_id) do
      dynamic = dynamic([gateways: g], g.site_id == ^site_id)
      {queryable, dynamic}
    end

    def fetch_gateway(id, subject) do
      result =
        from(g in Gateway, as: :gateways)
        |> where([gateways: g], g.id == ^id)
        |> preload([:ipv4_address, :ipv6_address])
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        gateway -> {:ok, gateway}
      end
    end

    def delete_gateway(gateway, subject) do
      case Safe.scoped(gateway, subject) |> Safe.delete() do
        {:ok, deleted_gateway} ->
          {:ok, Presence.Gateways.preload_gateways_presence([deleted_gateway]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
