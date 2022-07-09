defmodule FzHttpWeb.UserSocket do
  use Phoenix.Socket

  alias FzHttp.Users
  alias FzHttpWeb.HeaderHelpers

  require Logger

  ## Channels
  # channel "room:*", FzHttpWeb.RoomChannel
  channel "notification:session", FzHttpWeb.NotificationChannel

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
    # XXX: Might need to do something similar to convert_ip again
    ip =
      RemoteIp.from(connect_info[:x_headers],
        headers: HeaderHelpers.ip_x_headers(),
        proxy: HeaderHelpers.trusted_proxy()
      )

    if is_nil(ip) do
      :error
    else
      case Phoenix.Token.verify(socket, "user auth", token, max_age: 86_400) do
        {:ok, user_id} ->
          {:ok,
           socket
           |> assign(:current_user, Users.get_user!(user_id))
           |> assign(:remote_ip, ip)}

        {:error, _} ->
          :error
      end
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
end
