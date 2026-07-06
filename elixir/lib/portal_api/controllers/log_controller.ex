defmodule PortalAPI.LogController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias PortalAPI.Schemas.ProblemDetails
  alias Portal.Types.EventId
  alias __MODULE__.Database

  # Default window when `begin` is omitted from a list request.
  @default_window_days 90

  @types %{
    "change" => :change,
    "session" => :session,
    "flow" => :flow
  }

  # The event_id high nibble (its first hex character) identifies the stream
  # an entry belongs to, so show requests dispatch on it.
  @nibbles_to_types %{
    "c" => :change,
    "5" => :session,
    "f" => :flow
  }

  tags(["Logs"])

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation(:index,
    summary: "List Logs",
    description: """
    Lists log entries of the requested `type` for the authenticated account.

    - `change`: audit entries recording each insert, update, or delete event
      against an account-scoped object, most recent first.
    - `session`: one entry per Client, Gateway, or Portal session created,
      most recent first.
    - `flow`: one entry per network flow reported by Clients and Gateways,
      most recently started first.

    The `begin` and `end` query parameters bound the time window. For
    `change` and `session`, entries match when their
    `timestamp` falls inside the window; for `flow`, entries match when
    the flow was active at any point inside the window, i.e. when
    `[flow_start, flow_end)` overlaps it. Both must be RFC 3339 (ISO
    8601) timestamps, for example `2026-05-26T00:00:00Z`; values with a
    non-UTC offset are accepted and converted to UTC. When omitted,
    `begin` defaults to 90 days before the current time and `end`
    defaults to the current time. `begin` must be less than or equal to
    `end`.

    Results can be further narrowed by `actor_id` or `actor_email`, which
    matches the email recorded when the entry was created.

    Use the `next_page` cursor returned in `metadata` to fetch the
    following page of results.
    """,
    parameters: [
      type: [
        in: :query,
        required: true,
        description:
          "The log stream to list. One of `change`, `session`, or `flow`.",
        type: :string,
        example: "change"
      ],
      limit: [
        in: :query,
        description: """
        Maximum number of Logs to return per page. Defaults to 50.
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
        Inclusive start of the time window. RFC 3339 timestamp; non-UTC
        offsets are accepted and converted to UTC. Defaults to 90 days
        before the current time when omitted.
        """,
        type: :string,
        example: "2026-02-25T00:00:00Z"
      ],
      end: [
        in: :query,
        description: """
        Inclusive end of the time window. RFC 3339 timestamp; non-UTC
        offsets are accepted and converted to UTC. Defaults to the current
        time when omitted.
        """,
        type: :string,
        example: "2026-05-26T00:00:00Z"
      ],
      actor_id: [
        in: :query,
        description: "Filter to entries whose actor matches.",
        type: :string,
        example: "84e7f82f-831a-4a9d-8f17-c66c2bb6e205"
      ],
      actor_email: [
        in: :query,
        description: """
        Filter to entries whose actor email matches the email recorded
        when the entry was created. Supported for `change`, `session`, and
        `flow` types.
        """,
        type: :string,
        example: "admin@example.com"
      ]
    ],
    responses:
      [ok: {"Logs Response", "application/json", PortalAPI.Schemas.Log.ListResponse}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])
  )

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    pagination_opts = Pagination.params_to_list_opts(params)

    with {:ok, type} <- parse_type(params),
         {:ok, filters} <- coerce_filters(type, params),
         {:ok, logs, metadata} <-
           Database.list_logs(
             type,
             conn.assigns.subject,
             Keyword.put(pagination_opts, :filter, filters)
           ) do
      render(conn, :index, logs: logs, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation(:show,
    summary: "Show Log",
    description: """
    Fetches a single Log entry by its `event_id`. The entry's type is
    determined from the `event_id` itself: its first character identifies
    the log stream (`c` change, `5` session, `f` flow).
    """,
    parameters: [
      event_id: [
        in: :path,
        description:
          "Identifier of the Log entry. A 24-character lowercase hexadecimal string.",
        type: :string,
        example: "c00060db0c2c8eb400000000"
      ]
    ],
    responses:
      [ok: {"Log Response", "application/json", PortalAPI.Schemas.Log.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests, :not_found])
  )

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"event_id" => event_id}) do
    with {:ok, event_id} <- parse_event_id(event_id),
         {:ok, type} <- type_from_event_id(event_id),
         {:ok, log} <- Database.fetch_log(type, event_id, conn.assigns.subject) do
      render(conn, :show, log: log)
    else
      error -> Error.handle(conn, error)
    end
  end

  defp parse_type(%{"type" => type}) when is_map_key(@types, type) do
    {:ok, Map.fetch!(@types, type)}
  end

  defp parse_type(%{"type" => _type}) do
    {:error, :bad_request, reason: "`type` must be one of: change, session, flow"}
  end

  defp parse_type(_params) do
    {:error, :bad_request,
     reason: "`type` is required and must be one of: change, session, flow"}
  end

  defp type_from_event_id(<<nibble::binary-size(1), _rest::binary>>)
       when is_map_key(@nibbles_to_types, nibble) do
    {:ok, Map.fetch!(@nibbles_to_types, nibble)}
  end

  # A well-formed event_id whose high nibble is not a known log stream cannot
  # reference anything.
  defp type_from_event_id(_event_id), do: {:error, :not_found}

  defp coerce_filters(type, params) do
    now = DateTime.utc_now()
    default_begin = DateTime.add(now, -@default_window_days * 24 * 60 * 60, :second)

    with {:ok, begin_at} <- parse_timestamp(params["begin"], "begin", default_begin),
         {:ok, end_at} <- parse_timestamp(params["end"], "end", now),
         :ok <- validate_window(begin_at, end_at),
         {:ok, actor_id} <- parse_uuid(params["actor_id"], "actor_id"),
         {:ok, actor_email} <- parse_string(params["actor_email"], "actor_email"),
         :ok <- validate_type_filters(type, actor_email) do
      filters =
        [begin: begin_at, end: end_at]
        |> maybe_append(:actor_id, actor_id)
        |> maybe_append(:actor_email, actor_email)

      {:ok, filters}
    end
  end

  defp validate_type_filters(_type, _actor_email), do: :ok

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
    alias Portal.FlowLog
    alias Portal.Safe
    alias Portal.SessionLog

    def list_logs(:change, subject, opts) do
      from(cl in ChangeLog, as: :logs)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__.Change, opts)
    end

    def list_logs(:session, subject, opts) do
      from(sl in SessionLog, as: :logs)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__.Session, opts)
    end

    def list_logs(:flow, subject, opts) do
      from(fl in FlowLog, as: :logs)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__.Flow, opts)
    end

    def fetch_log(type, event_id, subject) do
      result =
        type
        |> by_event_id_query(event_id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        log -> {:ok, log}
      end
    end

    defp by_event_id_query(:change, event_id) do
      from(cl in ChangeLog, as: :logs, where: cl.event_id == ^event_id)
    end

    defp by_event_id_query(:session, event_id) do
      from(sl in SessionLog, as: :logs, where: sl.event_id == ^event_id)
    end

    defp by_event_id_query(:flow, event_id) do
      from(fl in FlowLog, as: :logs, where: fl.event_id == ^event_id)
    end

    defmodule Change do
      import Ecto.Query

      # change_log event_ids encode commit order, so they are the cursor.
      def cursor_fields do
        [{:logs, :desc, :event_id}]
      end

      def filters do
        [
          %Portal.Repo.Filter{name: :begin, type: :datetime, fun: &filter_by_begin/2},
          %Portal.Repo.Filter{name: :end, type: :datetime, fun: &filter_by_end/2},
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

      defp filter_by_begin(queryable, %DateTime{} = begin_at) do
        {queryable, dynamic([logs: l], l.timestamp >= ^begin_at)}
      end

      defp filter_by_end(queryable, %DateTime{} = end_at) do
        {queryable, dynamic([logs: l], l.timestamp <= ^end_at)}
      end

      defp filter_by_actor_id(queryable, actor_id) do
        {queryable, dynamic([logs: l], fragment("?->>'actor_id' = ?", l.subject, ^actor_id))}
      end

      defp filter_by_actor_email(queryable, actor_email) do
        {queryable,
         dynamic([logs: l], fragment("?->>'actor_email' = ?", l.subject, ^actor_email))}
      end
    end

    defmodule Session do
      import Ecto.Query

      # session_log event_ids are random, so order by timestamp with the
      # event_id as a unique tie-breaker.
      def cursor_fields do
        [{:logs, :desc, :timestamp}, {:logs, :desc, :event_id}]
      end

      def filters do
        [
          %Portal.Repo.Filter{name: :begin, type: :datetime, fun: &filter_by_begin/2},
          %Portal.Repo.Filter{name: :end, type: :datetime, fun: &filter_by_end/2},
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

      defp filter_by_begin(queryable, %DateTime{} = begin_at) do
        {queryable, dynamic([logs: l], l.timestamp >= ^begin_at)}
      end

      defp filter_by_end(queryable, %DateTime{} = end_at) do
        {queryable, dynamic([logs: l], l.timestamp <= ^end_at)}
      end

      defp filter_by_actor_id(queryable, actor_id) do
        {queryable, dynamic([logs: l], fragment("?->>'actor_id' = ?", l.subject, ^actor_id))}
      end

      # Matches the email snapshot taken at session creation, like change
      # and flow logs, so it survives actor deletion and email changes.
      defp filter_by_actor_email(queryable, actor_email) do
        {queryable,
         dynamic([logs: l], fragment("?->>'actor_email' = ?", l.subject, ^actor_email))}
      end
    end

    defmodule Flow do
      import Ecto.Query

      # flow_log event_ids are random, so order by when the flow started,
      # with the event_id as a unique tie-breaker.
      def cursor_fields do
        [{:logs, :desc, :flow_start}, {:logs, :desc, :event_id}]
      end

      def filters do
        [
          %Portal.Repo.Filter{name: :begin, type: :datetime, fun: &filter_by_begin/2},
          %Portal.Repo.Filter{name: :end, type: :datetime, fun: &filter_by_end/2},
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

      # The window matches flows that were active at any point inside it:
      # the flow's [flow_start, flow_end) range must overlap [begin, end].
      # Each bound is written as a range-overlap against
      # tstzrange(flow_start, flow_end, '[)') so it matches the expression
      # indexed by the flow_logs_unique_flow_per_window exclusion constraint
      # and can be served by its GiST index.
      defp filter_by_begin(queryable, %DateTime{} = begin_at) do
        {queryable,
         dynamic(
           [logs: l],
           fragment(
             "tstzrange(?, ?, '[)') && tstzrange(?, NULL, '[)')",
             l.flow_start,
             l.flow_end,
             ^begin_at
           )
         )}
      end

      defp filter_by_end(queryable, %DateTime{} = end_at) do
        {queryable,
         dynamic(
           [logs: l],
           fragment(
             "tstzrange(?, ?, '[)') && tstzrange(NULL, ?, '(]')",
             l.flow_start,
             l.flow_end,
             ^end_at
           )
         )}
      end

      defp filter_by_actor_id(queryable, actor_id) do
        {queryable, dynamic([logs: l], l.actor_id == ^actor_id)}
      end

      # Flow logs snapshot the actor email at ingestion (reported by the
      # gateway's accounting), so the filter matches the email at flow time
      # and survives actor deletion.
      defp filter_by_actor_email(queryable, actor_email) do
        {queryable, dynamic([logs: l], l.actor_email == ^actor_email)}
      end
    end

  end
end
