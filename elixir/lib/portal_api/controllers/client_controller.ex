defmodule PortalAPI.ClientController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias Portal.Presence.Clients
  alias __MODULE__.Database
  import Ecto.Changeset
  import Portal.Changeset

  tags(["Clients"])

  operation(:index,
    summary: "List Clients",
    parameters: [
      limit: [
        in: :query,
        description: "Limit Clients returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.ListResponse}
    ]
  )

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    list_opts =
      params
      |> Pagination.params_to_list_opts()
      |> Keyword.put(:preload, [:online?, :ipv4_address, :ipv6_address])

    with {:ok, clients, metadata} <- Database.list_clients(conn.assigns.subject, list_opts) do
      render(conn, :index, clients: clients, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation(:show,
    summary: "Show Client",
    parameters: [
      id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.Response}
    ]
  )

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, client} <- Database.fetch_client(id, conn.assigns.subject) do
      client = Clients.preload_clients_presence([client]) |> List.first()
      render(conn, :show, client: client)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation(:update,
    summary: "Update Client",
    parameters: [
      id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Client Attributes", "application/json", PortalAPI.Schemas.Client.Request, required: true},
    responses: [
      ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.Response}
    ]
  )

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id, "client" => params}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Database.fetch_client(id, subject),
         changeset = update_changeset(client, params),
         {:ok, client} <- Database.update_client(changeset, subject) do
      render(conn, :show, client: client)
    else
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  defp update_changeset(client, attrs) do
    import Ecto.Changeset
    update_fields = ~w[name]a
    required_fields = ~w[external_id name public_key]a

    client
    |> cast(attrs, update_fields)
    |> validate_required(required_fields)
    |> Portal.Client.changeset()
  end

  operation(:verify,
    summary: "Verify Client",
    parameters: [
      id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.Response}
    ]
  )

  @spec verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Database.fetch_client(id, subject),
         changeset = client |> change() |> put_default_value(:verified_at, DateTime.utc_now()),
         {:ok, client} <- Database.verify_client(changeset, subject) do
      render(conn, :show, client: client)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation(:unverify,
    summary: "Unverify Client",
    parameters: [
      id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.Response}
    ]
  )

  @spec unverify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unverify(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Database.fetch_client(id, subject),
         changeset = client |> change() |> put_change(:verified_at, nil),
         {:ok, client} <- Database.remove_client_verification(changeset, subject) do
      render(conn, :show, client: client)
    else
      error -> Error.handle(conn, error)
    end
  end

  operation(:delete,
    summary: "Delete a Client",
    parameters: [
      id: [
        in: :path,
        description: "Client ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses: [
      ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.Response}
    ]
  )

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Database.fetch_client(id, subject),
         {:ok, client} <- Database.delete_client(client, subject) do
      render(conn, :show, client: client)
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Presence.Clients, Repo, Authorization}
    alias Portal.Client

    def list_clients(subject, opts \\ []) do
      Authorization.with_subject(subject, fn ->
        from(c in Client, as: :clients)
        |> Repo.list(__MODULE__, opts)
      end)
    end

    def cursor_fields do
      [
        {:clients, :asc, :inserted_at},
        {:clients, :asc, :id}
      ]
    end

    def preloads do
      [
        online?: &Clients.preload_clients_presence/1
      ]
    end

    def fetch_client(id, subject) do
      Authorization.with_subject(subject, fn ->
        from(c in Client, as: :clients)
        |> where([clients: c], c.id == ^id)
        |> preload([:ipv4_address, :ipv6_address])
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          client -> {:ok, client}
        end
      end)
    end

    def update_client(changeset, subject) do
      case Authorization.with_subject(subject, fn -> Repo.update(changeset) end) do
        {:ok, updated_client} ->
          {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def verify_client(changeset, subject) do
      case Authorization.with_subject(subject, fn -> Repo.update(changeset) end) do
        {:ok, updated_client} ->
          {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def remove_client_verification(changeset, subject) do
      case Authorization.with_subject(subject, fn -> Repo.update(changeset) end) do
        {:ok, updated_client} ->
          {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def delete_client(client, subject) do
      case Authorization.with_subject(subject, fn -> Repo.delete(client) end) do
        {:ok, deleted_client} ->
          {:ok, Clients.preload_clients_presence([deleted_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
