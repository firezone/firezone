defmodule FzHttpWeb.NotificationChannelTest do
  use FzHttpWeb.ChannelCase, async: true

  alias FzHttp.UsersFixtures
  alias FzHttpWeb.NotificationChannel

  describe "channel join" do
    setup _tags do
      user = UsersFixtures.user()

      socket =
        FzHttpWeb.UserSocket
        |> socket(user.id, %{remote_ip: "127.0.0.1", user_agent: "test"})

      %{
        user: user,
        socket: socket,
        token: Phoenix.Token.sign(socket, "channel auth", user.id)
      }
    end

    test "joins channel with valid token", %{token: token, socket: socket, user: user} do
      payload = %{
        "token" => token
      }

      {:ok, _, test_socket} =
        socket
        |> subscribe_and_join(NotificationChannel, "notification:session", payload)

      assert test_socket.assigns.current_user.id == user.id
    end

    test "prevents joining with invalid token", %{token: _token, socket: socket, user: _user} do
      payload = %{
        "token" => "foobar"
      }

      assert {:error, %{reason: "unauthorized"}} ==
               socket
               |> subscribe_and_join(NotificationChannel, "notification:session", payload)
    end
  end
end
