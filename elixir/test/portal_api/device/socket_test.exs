defmodule PortalAPI.Device.SocketTest do
  use PortalAPI.ChannelCase, async: true
  alias PortalAPI.Device.Socket

  import Portal.TokenFixtures

  setup do
    Portal.Config.put_env_override(:client_session_queue,
      name: {:via, Registry, {Portal.Test.QueueRegistry, {self(), :client_session_queue}}}
    )

    encoded_token = client_token_fixture() |> encode_token()
    %{encoded_token: encoded_token}
  end

  describe "connect/3" do
    test "keeps the range the device states", %{encoded_token: encoded_token} do
      assert {:ok, socket} = connect_device(encoded_token, %{"proto_min" => "5", "proto_max" => "7"})
      assert socket.assigns.proto_range == %{min: 5, max: 7}
      assert socket.assigns.client.id
    end

    test "refuses a connect without a protocol range", %{encoded_token: encoded_token} do
      assert connect_device(encoded_token, %{}) == {:error, :invalid_proto_range}
    end

    test "refuses a range that is not whole numbers", %{encoded_token: encoded_token} do
      assert connect_device(encoded_token, %{"proto_min" => "1.5", "proto_max" => "7"}) ==
               {:error, :invalid_proto_range}
    end

    test "refuses a range whose minimum is above its maximum", %{encoded_token: encoded_token} do
      assert connect_device(encoded_token, %{"proto_min" => "8", "proto_max" => "7"}) ==
               {:error, :invalid_proto_range}
    end

    test "keeps whether the device connects without ICE", %{encoded_token: encoded_token} do
      range = %{"proto_min" => "5", "proto_max" => "7"}

      assert {:ok, socket} = connect_device(encoded_token, Map.put(range, "frostlink", "true"))
      assert socket.assigns.iceless_capable

      assert {:ok, socket} = connect_device(encoded_token, range)
      refute socket.assigns.iceless_capable
    end

    test "checks the token before the range" do
      assert connect_device("invalid", %{}) == {:error, :invalid_token}
    end
  end

  defp connect_device(encoded_token, range) do
    attrs =
      %{
        "token" => encoded_token,
        "external_id" => Ecto.UUID.generate(),
        "public_key" => Portal.DeviceFixtures.generate_public_key()
      }
      |> Map.merge(range)

    connect(Socket, attrs, connect_info: build_connect_info(token: encoded_token))
  end
end
