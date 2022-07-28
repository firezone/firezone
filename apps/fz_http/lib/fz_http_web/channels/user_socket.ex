defmodule FzHttpWeb.UserSocket do
  use Phoenix.Socket

  alias FzHttp.Users
  alias FzHttpWeb.HeaderHelpers
  import FzCommon.FzNet, only: [convert_ip: 1]

  @blank_ip_error {:error, "client IP couldn't be determined!"}

  # 4 hour channel tokens
  @token_verify_opts [max_age: 86_400]

  require Logger

  ## Channels
  # channel "room:*", FzHttpWeb.RoomChannel
  channel("notification:*", FzHttpWeb.NotificationChannel)

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
    case get_ip_address(connect_info) do
      ip when ip in ["", nil] ->
        @blank_ip_error

      ip ->
        verify_token_and_assign_remote_ip(socket, token, convert_ip(ip))
    end
  end

  defp verify_token_and_assign_remote_ip(socket, token, ip) do
    case Phoenix.Token.verify(socket, "user auth", token, @token_verify_opts) do
      {:ok, user_id} ->
        {:ok,
         socket
         |> assign(:current_user, Users.get_user!(user_id))
         |> assign(:remote_ip, ip)}

      {:error, reason} ->
        {:error, reason}
    end
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
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"

  # Proxied
  defp get_ip_address(%{x_headers: x_headers}) do
    RemoteIp.from(x_headers, HeaderHelpers.remote_ip_opts())
  end

  # No proxy
  defp get_ip_address(%{peer_data: %{address: address}}) do
    convert_ip(address)
  end
end
