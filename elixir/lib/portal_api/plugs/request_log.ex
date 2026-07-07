defmodule PortalAPI.Plugs.RequestLog do
  @moduledoc """
  Synchronously records one api_request_logs row for every authenticated REST
  API request, before the request is dispatched. The insert is intentionally
  load-bearing: if it fails, the request fails. We never allow an API
  operation to proceed unlogged.
  """
  alias __MODULE__.Database
  alias Portal.Types.EventId

  # Bandit caps the request line well below this; the slice is a guard against
  # the column growing unbounded if that ever changes.
  @max_path_length 2048

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, _api_request_log} =
      conn
      |> attrs()
      |> Database.insert_api_request_log()

    conn
  end

  defp attrs(conn) do
    subject = conn.assigns.subject
    {context, _version} = PortalAPI.Sockets.truncate_session_fields(subject.context, nil)

    %{
      account_id: subject.account.id,
      event_id: EventId.build_api_request_log(),
      actor_id: subject.actor.id,
      api_token_id: subject.credential.id,
      method: conn.method,
      path: String.slice(conn.request_path, 0, @max_path_length),
      content_length: content_length(conn),
      request_id: request_id(conn),
      user_agent: context.user_agent,
      ip: context.remote_ip,
      ip_region: context.remote_ip_location_region,
      ip_city: context.remote_ip_location_city,
      ip_lat: context.remote_ip_location_lat,
      ip_lon: context.remote_ip_location_lon
    }
  end

  defp content_length(conn) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [value | _rest] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> length
          _other -> nil
        end

      [] ->
        nil
    end
  end

  # Plug.RequestId runs in the endpoint before the router, so the header is
  # always present here.
  defp request_id(conn) do
    [request_id | _rest] = Plug.Conn.get_resp_header(conn, "x-request-id")
    request_id
  end

  defmodule Database do
    import Ecto.Changeset

    alias Portal.APIRequestLog
    alias Portal.Safe

    @cast_fields ~w[
      account_id
      event_id
      actor_id
      api_token_id
      method
      path
      content_length
      request_id
      user_agent
      ip
      ip_region
      ip_city
      ip_lat
      ip_lon
    ]a

    def insert_api_request_log(attrs) do
      %APIRequestLog{}
      |> cast(attrs, @cast_fields)
      |> APIRequestLog.changeset()
      |> Safe.unscoped()
      |> Safe.insert()
    end
  end
end
