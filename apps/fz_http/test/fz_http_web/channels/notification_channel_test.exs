defmodule FzHttpWeb.NotificationChannelTest do
  use FzHttpWeb.ChannelCase, async: true

  alias FzHttp.UsersFixtures
  alias FzHttpWeb.NotificationChannel

  describe "channel join" do
    setup _tags do
      user = UsersFixtures.user()

      socket =
        FzHttpWeb.UserSocket
        |> socket(user.id, %{remote_ip: "127.0.0.1", user_agent: "test", current_user_id: user.id})

      %{
        user: user,
        socket: socket,
        token: Phoenix.Token.sign(socket, "channel auth", user.id)
      }
    end

    test "joins channel ", %{socket: socket, user: user} do
      {:ok, _, test_socket} =
        socket
        |> subscribe_and_join(NotificationChannel, "notification:session", %{})

      assert test_socket.assigns.current_user.id == user.id
    end
  end
end
