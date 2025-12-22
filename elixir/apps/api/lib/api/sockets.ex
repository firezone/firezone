defmodule API.Sockets do
  @moduledoc """
  This module provides a set of helper function for Phoenix sockets and
  error handling around them.
  """
  require Logger

  def options(websocket_overrides \\ []) do
    [
      websocket:
        Keyword.merge(
          [
            transport_log: :debug,
            check_origin: :conn,
            connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers],
            error_handler: {__MODULE__, :handle_error, []}
          ],
          websocket_overrides
        ),
      longpoll: false
    ]
  end

  def handle_error(conn, :invalid_token),
    do: Plug.Conn.send_resp(conn, 401, "Invalid token")

  def handle_error(conn, :missing_token),
    do: Plug.Conn.send_resp(conn, 401, "Missing token")

  def handle_error(conn, :account_disabled),
    do: Plug.Conn.send_resp(conn, 403, "The account is disabled")

  def handle_error(conn, :unauthenticated),
    do: Plug.Conn.send_resp(conn, 403, "Forbidden")

  def handle_error(conn, %Ecto.Changeset{} = changeset) do
    Logger.error("Invalid connection request", changeset: inspect(changeset))
    errors = Domain.Changeset.errors_to_string(changeset)
    Plug.Conn.send_resp(conn, 422, "Invalid or missing connection parameters: #{errors}")
  end

  def handle_error(conn, :rate_limit),
    do: Plug.Conn.send_resp(conn, 429, "Too many requests")

  def auth_context(%{user_agent: user_agent, x_headers: x_headers, peer_data: peer_data}, type) do
    remote_ip = real_ip(x_headers, peer_data)
    Domain.Auth.Context.build(remote_ip, user_agent, x_headers, type)
  end

  defp real_ip(x_headers, peer_data) do
    real_ip =
      if is_list(x_headers) and x_headers != [] do
        RemoteIp.from(x_headers, API.Endpoint.real_ip_opts())
      end

    real_ip || peer_data.address
  end
end
