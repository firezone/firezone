defmodule API.Device.SocketTest do
  use API.ChannelCase, async: true
  import API.Device.Socket, only: [id: 1]
  alias API.Device.Socket
  alias Domain.Auth
  alias Domain.{AuthFixtures, DevicesFixtures}

  @connect_info %{
    user_agent: "iOS/12.7 (iPhone) connlib/0.1.1",
    peer_data: %{address: {189, 172, 73, 153}}
  }

  describe "connect/3" do
    test "returns error when token is missing" do
      assert connect(Socket, %{}, @connect_info) == {:error, :missing_token}
    end

    test "returns error when token is invalid" do
      attrs = connect_attrs(token: "foo")
      assert connect(Socket, attrs, @connect_info) == {:error, :invalid_token}
    end

    test "creates a new device" do
      subject = AuthFixtures.create_subject()
      {:ok, token} = Auth.create_session_token_from_subject(subject)

      attrs = connect_attrs(token: token)

      assert {:ok, socket} = connect(Socket, attrs, connect_info(subject))
      assert device = Map.fetch!(socket.assigns, :device)

      assert device.external_id == attrs["external_id"]
      assert device.public_key == attrs["public_key"]
      assert device.last_seen_user_agent == subject.context.user_agent
      assert device.last_seen_remote_ip.address == subject.context.remote_ip
      assert device.last_seen_version == "0.7.412"
    end

    test "updates existing device" do
      subject = AuthFixtures.create_subject()
      existing_device = DevicesFixtures.create_device(subject: subject)
      {:ok, token} = Auth.create_session_token_from_subject(subject)

      attrs = connect_attrs(token: token, external_id: existing_device.external_id)

      assert {:ok, socket} = connect(Socket, attrs, connect_info(subject))
      assert device = Repo.one(Domain.Devices.Device)
      assert device.id == socket.assigns.device.id
    end
  end

  describe "id/1" do
    test "creates a channel for a device" do
      device = DevicesFixtures.create_device()
      socket = socket(API.Device.Socket, "", %{device: device})

      assert id(socket) == "device:#{device.id}"
    end
  end

  defp connect_info(subject) do
    %{
      user_agent: subject.context.user_agent,
      peer_data: %{address: subject.context.remote_ip}
    }
  end

  defp connect_attrs(attrs) do
    DevicesFixtures.device_attrs()
    |> Map.take(~w[external_id public_key]a)
    |> Map.merge(Enum.into(attrs, %{}))
    |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
  end
end
