defmodule PortalAPI.ClientSessionController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias __MODULE__.Database

  tags(["Client Sessions"])

  operation(:index,
    summary: "List Client Sessions",
    parameters: [
      limit: [
        in: :query,
        description: "Limit Client Sessions returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      client_id: [
        in: :query,
        description: "Filter by Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Client Sessions Response", "application/json",
         PortalAPI.Schemas.ClientSession.ListResponse}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, client_sessions, metadata} <-
           Database.list_client_sessions(conn.assigns.subject, params, list_opts) do
      render(conn, :index, client_sessions: client_sessions, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation(:show,
    summary: "Show Client Session",
    parameters: [
      id: [
        in: :path,
        description: "Client Session ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok:
        {"Client Session Response", "application/json", PortalAPI.Schemas.ClientSession.Response}
    ]
  )

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, client_session} <- Database.fetch_client_session(id, conn.assigns.subject) do
      render(conn, :show, client_session: client_session)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.ClientSession
    alias Portal.Safe

    def list_client_sessions(subject, params, opts \\ []) do
      query = from(cs in ClientSession, as: :client_sessions)

      query =
        case params do
          %{"client_id" => client_id} ->
            where(query, [client_sessions: cs], cs.client_id == ^client_id)

          _ ->
            query
        end

      query
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:client_sessions, :desc, :inserted_at},
        {:client_sessions, :asc, :id}
      ]
    end

    def preloads do
      []
    end

    def fetch_client_session(id, subject) do
      result =
        from(cs in ClientSession, as: :client_sessions)
        |> where([client_sessions: cs], cs.id == ^id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        client_session -> {:ok, client_session}
      end
    end
  end
end
