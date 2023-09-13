defmodule API.Sockets do
  @moduledoc """
  This module provides a set of helper function for Phoenix sockets and
  error handling around them.
  """

  def options do
    [
      websocket: [
        transport_log: :debug,
        check_origin: :conn,
        connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers],
        error_handler: {__MODULE__, :handle_error, []}
      ],
      longpoll: false
    ]
  end

  def handle_error(conn, :invalid_token),
    do: Plug.Conn.send_resp(conn, 401, "Invalid token")

  def handle_error(conn, :unauthenticated),
    do: Plug.Conn.send_resp(conn, 403, "Forbidden")

  def handle_error(conn, %Ecto.Changeset{}),
    do: Plug.Conn.send_resp(conn, 422, "Invalid or missing connection parameters")

  def handle_error(conn, :rate_limit),
    do: Plug.Conn.send_resp(conn, 429, "Too many requests")

  def real_ip(x_headers, peer_data) do
    real_ip =
      if is_list(x_headers) and length(x_headers) > 0 do
        RemoteIp.from(x_headers, API.Endpoint.real_ip_opts())
      end

    real_ip || peer_data.address
  end

  # if Mix.env() == :test do
  #     defp maybe_allow_sandbox_access(%{user_agent: user_agent}) do
  #       %{owner: owner_pid, repo: repos} =
  #         metadata = Phoenix.Ecto.SQL.Sandbox.decode_metadata(user_agent)

  #       repos
  #       |> List.wrap()
  #       |> Enum.each(fn repo ->
  #         Ecto.Adapters.SQL.Sandbox.allow(repo, owner_pid, self())
  #       end)

  #       {:ok, metadata}
  #     end

  #     defp maybe_allow_sandbox_access(_), do: {:ok, %{}}
  #   else
  #     defp maybe_allow_sandbox_access(_), do: {:ok, %{}}
  #   end
end
