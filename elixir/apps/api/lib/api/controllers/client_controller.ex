defmodule API.ClientController do
  use API, :controller
  use OpenApiSpex.ControllerSpecs
  alias API.Pagination
  alias Domain.Presence.Clients
  alias __MODULE__.DB
  import Ecto.Changeset
  import Domain.Changeset

  action_fallback(API.FallbackController)

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
      ok: {"Client Response", "application/json", API.Schemas.Client.ListResponse}
    ]
  )

  # List Clients
  def index(conn, params) do
    list_opts =
      params
      |> Pagination.params_to_list_opts()
      |> Keyword.put(:preload, [:online?, :ipv4_address, :ipv6_address])

    with {:ok, clients, metadata} <- DB.list_clients(conn.assigns.subject, list_opts) do
      render(conn, :index, clients: clients, metadata: metadata)
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
      ok: {"Client Response", "application/json", API.Schemas.Client.Response}
    ]
  )

  # Show a specific Client
  def show(conn, %{"id" => id}) do
    with {:ok, client} <- DB.fetch_client(id, conn.assigns.subject) do
      client = Clients.preload_clients_presence([client]) |> List.first()
      render(conn, :show, client: client)
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
      {"Client Attributes", "application/json", API.Schemas.Client.Request, required: true},
    responses: [
      ok: {"Client Response", "application/json", API.Schemas.Client.Response}
    ]
  )

  # Update a Client
  def update(conn, %{"id" => id, "client" => params}) do
    subject = conn.assigns.subject

    with {:ok, client} <- DB.fetch_client(id, subject),
         changeset = update_changeset(client, params),
         {:ok, client} <- DB.update_client(changeset, subject) do
      render(conn, :show, client: client)
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

  defp update_changeset(client, attrs) do
    import Ecto.Changeset
    update_fields = ~w[name]a
    required_fields = ~w[external_id name public_key]a

    client
    |> cast(attrs, update_fields)
    |> validate_required(required_fields)
    |> Domain.Client.changeset()
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
      ok: {"Client Response", "application/json", API.Schemas.Client.Response}
    ]
  )

  # Verify a Client
  def verify(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- DB.fetch_client(id, subject),
         changeset = client |> change() |> put_default_value(:verified_at, DateTime.utc_now()),
         {:ok, client} <- DB.verify_client(changeset, subject) do
      render(conn, :show, client: client)
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
      ok: {"Client Response", "application/json", API.Schemas.Client.Response}
    ]
  )

  # Unverify a Client
  def unverify(conn, %{"id" => id}) do
    import Ecto.Changeset
    subject = conn.assigns.subject

    with {:ok, client} <- DB.fetch_client(id, subject),
         changeset = client |> change() |> put_change(:verified_at, nil),
         {:ok, client} <- DB.remove_client_verification(changeset, subject) do
      render(conn, :show, client: client)
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
      ok: {"Client Response", "application/json", API.Schemas.Client.Response}
    ]
  )

  # Delete a Client
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- DB.fetch_client(id, subject),
         {:ok, client} <- DB.delete_client(client, subject) do
      render(conn, :show, client: client)
    end
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Presence.Clients, Safe}
    alias Domain.Client

    def list_clients(subject, opts \\ []) do
      from(c in Client, as: :clients)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
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
      result =
        from(c in Client, as: :clients)
        |> where([clients: c], c.id == ^id)
        |> preload([:ipv4_address, :ipv6_address])
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        client -> {:ok, client}
      end
    end

    def update_client(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def verify_client(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def remove_client_verification(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def delete_client(client, subject) do
      case Safe.scoped(client, subject) |> Safe.delete() do
        {:ok, deleted_client} ->
          {:ok, Clients.preload_clients_presence([deleted_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
