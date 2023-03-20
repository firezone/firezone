defmodule FzHttpWeb.UserSocket do
  use Phoenix.Socket
  alias FzHttpWeb.HeaderHelpers

  @blank_ip_warning """
  Client IP couldn't be determined! Check to ensure your reverse proxy is properly sending the \
  X-Forwarded-For header. Read more in our reverse proxy docs: \
  https://docs.firezone.dev/deploy/reverse-proxies?utm_source=code \
  """

  # 1 day channel tokens
  @token_verify_opts [max_age: 86_400]

  require Logger

  ## Channels
  # channel "room:*", FzHttpWeb.RoomChannel
  channel("notification:session", FzHttpWeb.NotificationChannel)

  # Socket params are passed from the client and can
  # be used to verify and authenticate a user. After
  # verification, you can put default assigns into
  # the socket that will be set for all channels, ie
  #
  #     {:ok, assign(socket, :user_id, verified_user_id)}
  #
  # To deny connection, return `:error`.
  #
  # See `Phoenix.Token` documentation for examples in
  # performing token verification on connect.
  def connect(%{"token" => token}, socket, connect_info) do
    socket = assign(socket, :user_agent, connect_info[:user_agent])

    parse_ip(connect_info)
    |> verify_token_and_assign_remote_ip(token, socket)
  end

  defp parse_ip(connect_info) do
    case get_ip_address(connect_info) do
      ip when ip in ["", nil] ->
        Logger.warn(@blank_ip_warning,
          request_id: Keyword.get(Logger.metadata(), :request_id),
          remote_ip: ip
        )

        Logger.warn(connect_info,
          request_id: Keyword.get(Logger.metadata(), :request_id),
          remote_ip: ip
        )

        :x_forward_for_header_issue

      ip when is_tuple(ip) ->
        :inet.ntoa(ip) |> List.to_string()
    end
  end

  defp verify_token_and_assign_remote_ip(ip, token, socket) do
    case Phoenix.Token.verify(socket, "user auth", token, @token_verify_opts) do
      {:ok, user_id} ->
        socket =
          socket
          |> assign(:current_user_id, user_id)
          |> assign(:remote_ip, ip)

        {:ok, socket}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # No proxy
  defp get_ip_address(%{peer_data: %{address: address}, x_headers: []}) do
    address
  end

  # Proxied
  defp get_ip_address(%{x_headers: x_headers}) do
    RemoteIp.from(x_headers, HeaderHelpers.remote_ip_opts())
  end

  # Socket id's are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     FzHttpWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # Returning `nil` makes this socket anonymous.
  # def id(_socket), do: nil
  def id(socket), do: "user_socket:#{socket.assigns.current_user_id}"
end
