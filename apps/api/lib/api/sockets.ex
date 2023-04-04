defmodule API.Sockets do
  @moduledoc """
  This module provides a set of helper function for Phoenix sockets and
  error handling around them.
  """

  def options do
    [
      transport_log: :debug,
      check_origin: :conn,
      connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers],
      websocket: [
        error_handler: {__MODULE__, :handle_error, []}
      ],
      longpoll: false
    ]
  end

  def handle_error(conn, :unauthenticated), do: Plug.Conn.send_resp(conn, 403, "Forbidden")
  def handle_error(conn, :invalid), do: Plug.Conn.send_resp(conn, 422, "Unprocessable Entity")
  def handle_error(conn, :rate_limit), do: Plug.Conn.send_resp(conn, 429, "Too many requests")

  defp parse_ip(connect_info) do
    case get_ip_address(connect_info) do
      ip when ip in ["", nil] ->
        :x_forward_for_header_issue

      ip when is_tuple(ip) ->
        :inet.ntoa(ip) |> List.to_string()
    end
  end

  defp get_ip_address(%{peer_data: %{address: address}, x_headers: []}) do
    address
  end

  defp get_ip_address(%{x_headers: x_headers}) do
    RemoteIp.from(x_headers, HeaderHelpers.remote_ip_opts())
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
