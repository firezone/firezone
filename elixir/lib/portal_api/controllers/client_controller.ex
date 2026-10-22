defmodule PortalAPI.ClientController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.JSON
  alias PortalAPI.Error
  alias PortalAPI.Filters
  alias PortalAPI.Schemas.ProblemDetails
  alias Portal.Presence.Devices
  alias __MODULE__.Database
  import Ecto.Changeset
  import Portal.Changeset

  tags(["Clients"])

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation(:index,
    summary: "List Clients",
    parameters: [
      limit: [
        in: :query,
        description: "Limit Clients returned",
        schema: PortalAPI.Pagination.limit_schema(),
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string],
      name: [in: :query, description: "Filter to Clients with this exact name", type: :string],
      firezone_id: [
        in: :query,
        description: "Filter to the Client with this exact Firezone ID",
        type: :string
      ],
      actor_id: [
        in: :query,
        description: "Filter to Clients owned by this Actor",
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid}
      ],
      online: [
        in: :query,
        description: "Filter to Clients that are connected (`true`) or not connected (`false`) right now",
        schema: %OpenApiSpex.Schema{type: :boolean}
      ],
      last_seen_before: [
        in: :query,
        description: """
        Filter to Clients whose latest connection started before this RFC 3339 timestamp.
        A Client with no recorded `last_seen_at` counts as last seen when it was created.
        `last_seen_at` is set when a Client connects, so a Client that has stayed
        connected since before this time also matches; add `online=false` to leave it out.
        """,
        schema: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
        example: "2026-01-01T00:00:00Z"
      ],
      last_seen_after: [
        in: :query,
        description: """
        Filter to Clients whose latest connection started at or after this RFC 3339
        timestamp. A Client with no recorded `last_seen_at` counts as last seen when it
        was created.
        """,
        schema: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
        example: "2026-01-01T00:00:00Z"
      ],
      client_type: [
        in: :query,
        description: """
        Filter to Clients of this type, read from the user agent of the latest session:
        `headless` (Linux and Windows headless Clients), `gui` (Linux and Windows GUI
        Clients), `apple` (macOS and iOS), or `android`. Clients with no recorded user
        agent match no type.
        """,
        schema: %OpenApiSpex.Schema{type: :string, enum: ["headless", "gui", "apple", "android"]}
      ]
    ],
    responses:
      [ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.ListResponse}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])
  )

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    subject = conn.assigns.subject

    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         {:ok, filters} <- coerce_filters(params, subject),
         list_opts = Keyword.put(list_opts, :preload, [:online?]),
         list_opts = Keyword.put(list_opts, :filter, filters),
         {:ok, clients, metadata} <- Database.list_clients(subject, list_opts) do
      json(conn, JSON.encode(clients, metadata, schema: PortalAPI.Schemas.Client.GetSchema))
    else
      error -> Error.handle(conn, error)
    end
  end

  defp coerce_filters(params, subject) do
    with {:ok, last_seen_before} <- parse_timestamp(params["last_seen_before"]),
         {:ok, last_seen_after} <- parse_timestamp(params["last_seen_after"]) do
      {:ok,
       []
       |> Filters.maybe_append(:name, params["name"])
       |> Filters.maybe_append(:firezone_id, params["firezone_id"])
       |> Filters.maybe_append(:actor_id, params["actor_id"])
       |> Filters.maybe_append(:id, online_filter(params["online"], subject))
       |> Filters.maybe_append(:last_seen_before, last_seen_before)
       |> Filters.maybe_append(:last_seen_after, last_seen_after)
       |> Filters.maybe_append(:client_type, params["client_type"])}
    end
  end

  defp online_filter("true", subject), do: Devices.online_ids(subject.account.id, :client)

  defp online_filter("false", subject) do
    {:not_in, Devices.online_ids(subject.account.id, :client)}
  end

  defp online_filter(_online, _subject), do: nil

  defp parse_timestamp(nil), do: {:ok, nil}

  defp parse_timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} ->
        {:ok, timestamp}

      # coveralls-ignore-start - unreachable: request validation already requires a date-time
      {:error, _reason} ->
        {:error, :bad_request, reason: "timestamps must be RFC 3339"}
        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests, :not_found])
  )

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, client} <- Database.fetch_client(id, conn.assigns.subject) do
      client = Devices.preload_presence([client]) |> List.first()
      json(conn, JSON.encode(client, schema: PortalAPI.Schemas.Client.GetSchema))
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.Response}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :too_many_requests,
          :not_found,
          :unprocessable_entity
        ])
  )

  # coveralls-ignore-stop

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id, "client" => params}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Database.fetch_client(id, subject),
         changeset = update_changeset(client, params),
         {:ok, client} <- Database.update_client(changeset, subject) do
      json(conn, JSON.encode(client, schema: PortalAPI.Schemas.Client.GetSchema))
    else
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  defp update_changeset(device, attrs) do
    import Ecto.Changeset
    update_fields = ~w[name slug]a

    # A body that omits either keeps the stored value, but `cast/3` reads `""` as nil, and
    # both columns are NOT NULL. Requiring them turns a blank one into a 422 rather than a
    # constraint error.
    required_fields = ~w[name slug]a

    # `Safe.update/1` runs `Portal.Device.changeset/1` on the way in, so running it here
    # too would report every failed validation twice.
    device
    |> cast(attrs, update_fields)
    |> validate_required(required_fields)
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests, :not_found])
  )

  # coveralls-ignore-stop

  @spec verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Database.fetch_client(id, subject),
         changeset = client |> change() |> put_default_value(:verified_at, DateTime.utc_now()),
         {:ok, client} <- Database.verify_client(changeset, subject) do
      json(conn, JSON.encode(client, schema: PortalAPI.Schemas.Client.GetSchema))
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests, :not_found])
  )

  # coveralls-ignore-stop

  @spec unverify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unverify(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Database.fetch_client(id, subject),
         changeset = client |> change() |> put_change(:verified_at, nil),
         {:ok, client} <- Database.remove_client_verification(changeset, subject) do
      json(conn, JSON.encode(client, schema: PortalAPI.Schemas.Client.GetSchema))
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
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
    responses:
      [ok: {"Client Response", "application/json", PortalAPI.Schemas.Client.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests, :not_found])
  )

  # coveralls-ignore-stop

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, client} <- Database.fetch_client(id, subject),
         {:ok, client} <- Database.delete_client(client, subject) do
      json(conn, JSON.encode(client, schema: PortalAPI.Schemas.Client.GetSchema))
    else
      error -> Error.handle(conn, error)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Presence.Devices, Safe}
    alias Portal.Device

    def list_clients(subject, opts \\ []) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :client)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name,
          title: "Name",
          type: :string,
          fun: &filter_by_name/2
        },
        %Portal.Repo.Filter{
          name: :firezone_id,
          title: "Firezone ID",
          type: :string,
          fun: &filter_by_firezone_id/2
        },
        %Portal.Repo.Filter{
          name: :actor_id,
          title: "Actor",
          type: {:string, :uuid},
          fun: &filter_by_actor_id/2
        },
        %Portal.Repo.Filter{
          name: :id,
          title: "ID",
          type: {:list, {:string, :uuid}},
          fun: &filter_by_id/2
        },
        %Portal.Repo.Filter{
          name: :last_seen_before,
          title: "Last seen before",
          type: :datetime,
          fun: &filter_by_last_seen_before/2
        },
        %Portal.Repo.Filter{
          name: :last_seen_after,
          title: "Last seen after",
          type: :datetime,
          fun: &filter_by_last_seen_after/2
        },
        %Portal.Repo.Filter{
          name: :client_type,
          title: "Client type",
          type: {:string, :select},
          values: [
            {"Headless", "headless"},
            {"GUI", "gui"},
            {"Apple", "apple"},
            {"Android", "android"}
          ],
          fun: &filter_by_client_type/2
        }
      ]
    end

    defp filter_by_name(queryable, name) do
      dynamic = dynamic([devices: d], d.name == ^name)
      {queryable, dynamic}
    end

    # firezone_id is unique per (account_id, actor_id) for Clients, not
    # per account, so this can still match more than one row - callers
    # must handle that rather than assuming a single result.
    defp filter_by_firezone_id(queryable, firezone_id) do
      dynamic = dynamic([devices: d], d.firezone_id == ^firezone_id)
      {queryable, dynamic}
    end

    defp filter_by_actor_id(queryable, actor_id) do
      {queryable, dynamic([devices: d], d.actor_id == ^actor_id)}
    end

    defp filter_by_id(queryable, {:not_in, ids}) do
      {queryable, dynamic([devices: d], d.id not in ^ids)}
    end

    defp filter_by_id(queryable, ids) do
      {queryable, dynamic([devices: d], d.id in ^ids)}
    end

    # A Client row is created by its first connect, so inserted_at is a known connection.
    defp filter_by_last_seen_before(queryable, timestamp) do
      {queryable, dynamic([devices: d], coalesce(d.last_seen_at, d.inserted_at) < ^timestamp)}
    end

    defp filter_by_last_seen_after(queryable, timestamp) do
      {queryable, dynamic([devices: d], coalesce(d.last_seen_at, d.inserted_at) >= ^timestamp)}
    end

    defp filter_by_client_type(queryable, "headless") do
      {queryable, dynamic([devices: d], like(d.last_seen_user_agent, "%headless-client/%"))}
    end

    defp filter_by_client_type(queryable, "gui") do
      {queryable, dynamic([devices: d], like(d.last_seen_user_agent, "%gui-client/%"))}
    end

    defp filter_by_client_type(queryable, "apple") do
      {queryable,
       dynamic(
         [devices: d],
         like(d.last_seen_user_agent, "%apple-client/%") or
           like(d.last_seen_user_agent, "Mac OS%") or
           like(d.last_seen_user_agent, "macOS%") or
           like(d.last_seen_user_agent, "iOS%")
       )}
    end

    defp filter_by_client_type(queryable, "android") do
      {queryable,
       dynamic(
         [devices: d],
         like(d.last_seen_user_agent, "%android-client/%") or
           like(d.last_seen_user_agent, "Android%")
       )}
    end

    def cursor_fields do
      [
        {:devices, :asc, :inserted_at},
        {:devices, :asc, :id}
      ]
    end

    def preloads do
      [
        online?: &Devices.preload_presence/1
      ]
    end

    def fetch_client(id, subject) do
      result =
        from(d in Device, as: :devices)
        |> where([devices: d], d.id == ^id and d.type == :client)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil ->
          {:error, :not_found}

        client ->
          {:ok, client}
      end
    end

    def update_client(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, Devices.preload_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    def verify_client(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, Devices.preload_presence([updated_client]) |> List.first()}

        # coveralls-ignore-start - defensive: Safe.update on a server-built changeset cannot fail
        {:error, reason} ->
          {:error, reason}
          # coveralls-ignore-stop
      end
    end

    def remove_client_verification(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, Devices.preload_presence([updated_client]) |> List.first()}

        # coveralls-ignore-start - defensive: Safe.update on a server-built changeset cannot fail
        {:error, reason} ->
          {:error, reason}
          # coveralls-ignore-stop
      end
    end

    def delete_client(client, subject) do
      case Safe.scoped(client, subject) |> Safe.delete() do
        {:ok, deleted_client} ->
          {:ok, Devices.preload_presence([deleted_client]) |> List.first()}

        # coveralls-ignore-start - defensive: Safe.delete on an existing client cannot fail
        {:error, reason} ->
          {:error, reason}
          # coveralls-ignore-stop
      end
    end
  end
end
