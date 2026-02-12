defmodule PortalAPI.GatewaySessionController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Error
  alias PortalAPI.Pagination
  alias __MODULE__.Database

  tags(["Gateway Sessions"])

  operation(:index,
    summary: "List Gateway Sessions",
    parameters: [
      gateway_id: [
        in: :query,
        description: "Filter by Gateway ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Gateway Sessions Response", "application/json",
         PortalAPI.Schemas.GatewaySession.ListResponse}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, gateway_sessions, metadata} <-
           Database.list_gateway_sessions(conn.assigns.subject, params, list_opts) do
      render(conn, :index, gateway_sessions: gateway_sessions, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation(:show,
    summary: "Show Gateway Session",
    parameters: [
      id: [
        in: :path,
        description: "Gateway Session ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Gateway Session Response", "application/json",
         PortalAPI.Schemas.GatewaySession.Response}
    ]
  )

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, gateway_session} <- Database.fetch_gateway_session(id, conn.assigns.subject) do
      render(conn, :show, gateway_session: gateway_session)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.GatewaySession
    alias Portal.Safe

    def list_gateway_sessions(subject, params, opts \\ []) do
      query = from(gs in GatewaySession, as: :gateway_sessions)

      query =
        case params do
          %{"gateway_id" => gateway_id} ->
            where(query, [gateway_sessions: gs], gs.gateway_id == ^gateway_id)

          _ ->
            query
        end

      query
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:gateway_sessions, :desc, :inserted_at},
        {:gateway_sessions, :asc, :id}
      ]
    end

    def preloads do
      []
    end

    def fetch_gateway_session(id, subject) do
      result =
        from(gs in GatewaySession, as: :gateway_sessions)
        |> where([gateway_sessions: gs], gs.id == ^id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        gateway_session -> {:ok, gateway_session}
      end
    end
  end
end
