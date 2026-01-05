defmodule PortalAPI.Sockets do
  @moduledoc """
  This module provides a set of helper function for Phoenix sockets and
  error handling around them.
  """
  require Logger

  @doc """
  Extracts the token from connection parameters or headers.

  Checks the `x-authorization` header first (expecting "Bearer {token}" format),
  then falls back to the `token` query parameter.

  Returns `{:ok, token}` if found, or `{:error, :missing_token}` if no token is present.
  """
  def extract_token(params, connect_info) do
    with {:error, :missing_token} <- extract_token_from_header(connect_info) do
      extract_token_from_params(params)
    end
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
    Plug.Conn.send_resp(conn, 422, "Invalid or missing connection parameters")
  end

  # We use 503 instead of 429 because connlib treats 429 as fatal until
  # https://github.com/firezone/firezone/pull/11594 is widely distributed.
  def handle_error(conn, :rate_limit) do
    conn
    |> Plug.Conn.put_resp_header(
      "retry-after",
      Integer.to_string(PortalAPI.Sockets.RateLimit.retry_after_seconds())
    )
    |> Plug.Conn.send_resp(503, "Service Unavailable")
  end

  def auth_context(%{user_agent: user_agent, x_headers: x_headers, peer_data: peer_data}, type) do
    remote_ip = real_ip(x_headers, peer_data)
    Portal.Auth.Context.build(remote_ip, user_agent, x_headers, type)
  end

  defp real_ip(x_headers, peer_data) do
    real_ip =
      if is_list(x_headers) and x_headers != [] do
        RemoteIp.from(x_headers, PortalAPI.Endpoint.real_ip_opts())
      end

    real_ip || peer_data.address
  end

  defp extract_token_from_header(%{x_headers: x_headers}) when is_list(x_headers) do
    case List.keyfind(x_headers, "x-authorization", 0) do
      {"x-authorization", "Bearer " <> token} -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  defp extract_token_from_header(_connect_info), do: {:error, :missing_token}

  defp extract_token_from_params(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp extract_token_from_params(_params), do: {:error, :missing_token}
end
