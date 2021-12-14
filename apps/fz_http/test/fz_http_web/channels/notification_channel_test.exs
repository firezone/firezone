defmodule FzHttpWeb.NotificationChannelTest do
  use FzHttpWeb.ChannelCase

  alias FzHttp.UsersFixtures

  describe "channel join" do
    setup do
      %{
        user: FzHttp.UsersFixtures.user(),
        socket: socket(user.id, %{})
      }
    end

    test "joins channel with valid token", %{user: user} do
      # token = Phoenix.Token.sign
    end

    test "prevents joining with expired token", %{user: user} do
    end

    test "prevents joining with invalid token", %{user: user} do
    end
  end

  test "broadcasts are pushed to the client", %{socket: socket} do
    broadcast_from!(socket, "broadcast", %{"some" => "data"})
    assert_push "broadcast", %{"some" => "data"}
  end
end
