defmodule PortalAPI.ChangeLogController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias PortalAPI.Schemas.ProblemDetails
  alias Portal.Types.EventId
  alias __MODULE__.Database

  # Default window when `begin` is omitted from a list request.
  @default_window_days 90

  tags(["Change Logs"])

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation(:index,
    summary: "List Change Logs",
    description: """
    Lists audit Change Log entries for the authenticated account.

    Each entry records a single insert, update, or delete event against an
    account-scoped object. Entries are returned in `event_id` order with
    the most recent change first.

    The `begin` and `end` query parameters bound the window in which to
    look up Change Logs by their `timestamp`. Both must be RFC 3339 (ISO
    8601) timestamps, for example `2026-05-26T00:00:00Z`; values with a
    non-UTC offset are accepted and converted to UTC. When omitted,
    `begin` defaults to 90 days before the current time and `end`
    defaults to the current time. `begin` must be less than or equal to
    `end`.

    Results can be further narrowed by `actor_id` or `actor_email`, which
    match against the corresponding fields on the entry's `subject`.

    Use the `next_page` cursor returned in `metadata` to fetch the
    following page of results.
    """,
    parameters: [
      limit: [
        in: :query,
        description: """
        Maximum number of Change Logs to return per page. Defaults to 50.
        Values greater than 100 are capped to 100, and values less than 1
        are raised to 1.
        """,
        type: :integer,
        example: 50
      ],
      page_cursor: [
        in: :query,
        description: "Next/Prev page cursor returned by a previous request.",
        type: :string
      ],
      begin: [
        in: :query,
        description: """
        Inclusive lower bound on `timestamp`. RFC 3339 timestamp; non-UTC
        offsets are accepted and converted to UTC. Defaults to 90 days
        before the current time when omitted.
        """,
        type: :string,
        example: "2026-02-25T00:00:00Z"
      ],
      end: [
        in: :query,
        description: """
        Inclusive upper bound on `timestamp`. RFC 3339 timestamp; non-UTC
        offsets are accepted and converted to UTC. Defaults to the current
        time when omitted.
        """,
        type: :string,
        example: "2026-05-26T00:00:00Z"
      ],
      actor_id: [
        in: :query,
        description: "Filter to entries whose `subject.actor_id` matches.",
        type: :string,
        example: "84e7f82f-831a-4a9d-8f17-c66c2bb6e205"
      ],
      actor_email: [
        in: :query,
        description: "Filter to entries whose `subject.actor_email` matches.",
        type: :string,
        example: "admin@example.com"
      ]
    ],
    responses:
      [
        ok:
          {"Change Logs Response", "application/json", PortalAPI.Schemas.ChangeLog.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])
  )

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    pagination_opts = Pagination.params_to_list_opts(params)

    with {:ok, filters} <- coerce_filters(params),
         {:ok, change_logs, metadata} <-
           Database.list_change_logs(
             conn.assigns.subject,
             Keyword.put(pagination_opts, :filter, filters)
           ) do
      render(conn, :index, change_logs: change_logs, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation(:show,
    summary: "Show Change Log",
    description: """
    Fetches a single Change Log entry by its `event_id`.
    """,
    parameters: [
      event_id: [
        in: :path,
        description:
          "Identifier of the Change Log entry. A 24-character lowercase hexadecimal string.",
        type: :string,
        example: "c00060db0c2c8eb400000000"
      ]
    ],
    responses:
      [ok: {"Change Log Response", "application/json", PortalAPI.Schemas.ChangeLog.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests, :not_found])
  )

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"event_id" => event_id}) do
    with {:ok, event_id} <- parse_event_id(event_id),
         {:ok, change_log} <- Database.fetch_change_log(event_id, conn.assigns.subject) do
      render(conn, :show, change_log: change_log)
    else
      error -> Error.handle(conn, error)
    end
  end

  defp coerce_filters(params) do
    now = DateTime.utc_now()
    default_begin = DateTime.add(now, -@default_window_days * 24 * 60 * 60, :second)

    with {:ok, begin_at} <- parse_timestamp(params["begin"], "begin", default_begin),
         {:ok, end_at} <- parse_timestamp(params["end"], "end", now),
         :ok <- validate_window(begin_at, end_at),
         {:ok, actor_id} <- parse_uuid(params["actor_id"], "actor_id"),
         {:ok, actor_email} <- parse_string(params["actor_email"], "actor_email") do
      filters =
        [begin: begin_at, end: end_at]
        |> maybe_append(:actor_id, actor_id)
        |> maybe_append(:actor_email, actor_email)

      {:ok, filters}
    end
  end

  defp parse_timestamp(nil, _name, default), do: {:ok, default}
  defp parse_timestamp("", _name, default), do: {:ok, default}

  defp parse_timestamp(value, name, _default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _reason} ->
        {:error, :bad_request,
         reason: "`#{name}` must be an RFC 3339 timestamp (e.g. `2026-05-26T00:00:00Z`)"}
    end
  end

  defp parse_timestamp(_value, name, _default) do
    {:error, :bad_request, reason: "`#{name}` must be a string"}
  end

  defp parse_uuid(nil, _name), do: {:ok, nil}
  defp parse_uuid("", _name), do: {:ok, nil}

  defp parse_uuid(value, name) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :bad_request, reason: "`#{name}` must be a UUID"}
    end
  end

  defp parse_uuid(_value, name) do
    {:error, :bad_request, reason: "`#{name}` must be a string"}
  end

  defp parse_string(nil, _name), do: {:ok, nil}
  defp parse_string("", _name), do: {:ok, nil}
  defp parse_string(value, _name) when is_binary(value), do: {:ok, value}

  defp parse_string(_value, name) do
    {:error, :bad_request, reason: "`#{name}` must be a string"}
  end

  defp parse_event_id(value) do
    case EventId.parse(value) do
      {:ok, event_id} -> {:ok, event_id}
      :error -> {:error, :bad_request, reason: "`event_id` must be a 24-char hex string"}
    end
  end

  defp validate_window(begin_at, end_at) do
    if DateTime.compare(begin_at, end_at) in [:lt, :eq] do
      :ok
    else
      {:error, :bad_request, reason: "`begin` must be less than or equal to `end`"}
    end
  end

  defp maybe_append(filters, _name, nil), do: filters
  defp maybe_append(filters, name, value), do: filters ++ [{name, value}]

  defmodule Database do
    import Ecto.Query
    alias Portal.ChangeLog
    alias Portal.Safe

    def list_change_logs(subject, opts \\ []) do
      from(cl in ChangeLog, as: :change_logs)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [{:change_logs, :desc, :event_id}]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :begin,
          type: :datetime,
          fun: &filter_by_begin/2
        },
        %Portal.Repo.Filter{
          name: :end,
          type: :datetime,
          fun: &filter_by_end/2
        },
        %Portal.Repo.Filter{
          name: :actor_id,
          type: {:string, :uuid},
          fun: &filter_by_actor_id/2
        },
        %Portal.Repo.Filter{
          name: :actor_email,
          type: {:string, :email},
          fun: &filter_by_actor_email/2
        }
      ]
    end

    def fetch_change_log(event_id, subject) do
      result =
        from(cl in ChangeLog, as: :change_logs)
        |> where([change_logs: cl], cl.event_id == ^event_id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        change_log -> {:ok, change_log}
      end
    end

    defp filter_by_begin(queryable, %DateTime{} = begin_at) do
      {queryable, dynamic([change_logs: cl], cl.timestamp >= ^begin_at)}
    end

    defp filter_by_end(queryable, %DateTime{} = end_at) do
      {queryable, dynamic([change_logs: cl], cl.timestamp <= ^end_at)}
    end

    defp filter_by_actor_id(queryable, actor_id) do
      {queryable,
       dynamic([change_logs: cl], fragment("?->>'actor_id' = ?", cl.subject, ^actor_id))}
    end

    defp filter_by_actor_email(queryable, actor_email) do
      {queryable,
       dynamic([change_logs: cl], fragment("?->>'actor_email' = ?", cl.subject, ^actor_email))}
    end
  end
end
