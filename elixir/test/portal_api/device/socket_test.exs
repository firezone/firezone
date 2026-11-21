defmodule PortalAPI.Device.SocketTest do
  use PortalAPI.ChannelCase, async: true
  import Ecto.Query
  alias PortalAPI.Device.Socket

  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  @range %{"proto_min" => "5", "proto_max" => "7"}

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

    test "marks the client as last seen on /device/v1", %{encoded_token: encoded_token} do
      assert {:ok, socket} = connect_device(encoded_token, @range)
      assert socket.assigns.client.last_seen_device_v1
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

  describe "connect/3 with a Gateway token" do
    setup do
      account = account_fixture()
      site = site_fixture(account: account)
      %{account: account, site: site}
    end

    test "connects a site token as a gateway in the token's site", %{account: account, site: site} do
      token = gateway_token_fixture(account: account, site: site)
      encoded_token = encode_gateway_token(token)
      firezone_id = Ecto.UUID.generate()

      assert {:ok, socket} = connect_device(encoded_token, @range, firezone_id)

      assert socket.assigns.subject.actor.type == :legacy_gateway
      assert socket.assigns.token_id == token.id
      assert socket.assigns.client.type == :gateway
      assert socket.assigns.client.firezone_id == firezone_id
      assert socket.assigns.proto_range == %{min: 5, max: 7}
      assert Socket.id(socket) == Portal.Sockets.socket_id(token.id)
      refute Map.has_key?(socket.assigns, :gateway)

      assert Repo.get_by!(Portal.SiteDevice, device_id: socket.assigns.client.id).site_id == site.id
    end

    test "connects a device-bound token signed with the device salt to its gateway", %{
      account: account,
      site: site
    } do
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(gateway: gateway)

      assert {:ok, socket} = connect_device(Portal.Authentication.encode_fragment!(token), @range)

      assert socket.assigns.client.id == gateway.id
      assert socket.assigns.token_id == token.id
      assert socket.assigns.subject.actor.type == :legacy_gateway
    end

    test "connects the same device as /gateway for the same token and firezone_id", %{
      account: account,
      site: site
    } do
      encoded_token = gateway_token_fixture(account: account, site: site) |> encode_gateway_token()
      first_id = Ecto.UUID.generate()
      second_id = Ecto.UUID.generate()

      assert {:ok, gateway_socket} = connect_gateway(encoded_token, first_id)
      assert {:ok, device_socket} = connect_device(encoded_token, @range, first_id)
      assert device_socket.assigns.client.id == gateway_socket.assigns.gateway.id

      assert {:ok, device_socket} = connect_device(encoded_token, @range, second_id)
      assert {:ok, gateway_socket} = connect_gateway(encoded_token, second_id)
      assert gateway_socket.assigns.gateway.id == device_socket.assigns.client.id

      assert Repo.aggregate(where(Portal.Device, account_id: ^account.id), :count) == 2
    end

    test "refuses a device-bound gateway that is connected on /gateway", %{account: account, site: site} do
      gateway = gateway_fixture(account: account, site: site)
      encoded_token = gateway_token_fixture(gateway: gateway) |> encode_gateway_token()

      :ok = Portal.PG.join(gateway.id)

      assert connect_device(encoded_token, @range) == {:error, :conflict}
    end

    test "refuses a site-token gateway that is connected on /gateway", %{account: account, site: site} do
      gateway = gateway_fixture(account: account, site: site)
      encoded_token = gateway_token_fixture(account: account, site: site) |> encode_gateway_token()

      :ok = Portal.PG.join(gateway.id)

      assert connect_device(encoded_token, @range, gateway.firezone_id) == {:error, :conflict}
    end

    test "marks the gateway as last seen on /device/v1, and /gateway clears it", %{
      account: account,
      site: site
    } do
      encoded_token = gateway_token_fixture(account: account, site: site) |> encode_gateway_token()
      firezone_id = Ecto.UUID.generate()

      assert {:ok, device_socket} = connect_device(encoded_token, @range, firezone_id)
      assert device_socket.assigns.client.last_seen_device_v1

      Repo.update_all(where(Portal.Device, id: ^device_socket.assigns.client.id), set: [last_seen_device_v1: true])

      assert {:ok, gateway_socket} = connect_gateway(encoded_token, firezone_id)
      refute gateway_socket.assigns.gateway.last_seen_device_v1
    end

    test "refuses a deleted token", %{account: account, site: site} do
      token = gateway_token_fixture(account: account, site: site)
      Repo.delete!(token)

      assert connect_device(encode_gateway_token(token), @range) == {:error, :invalid_token}
    end

    test "refuses a connect without a protocol range", %{account: account, site: site} do
      encoded_token = gateway_token_fixture(account: account, site: site) |> encode_gateway_token()

      assert connect_device(encoded_token, %{}) == {:error, :invalid_proto_range}
    end

    test "connects a client token signed with the device salt as a client" do
      token = client_token_fixture()

      assert {:ok, socket} = connect_device(Portal.Authentication.encode_fragment!(token), @range)

      assert socket.assigns.client.type == :client
      assert socket.assigns.subject.actor.id == token.actor_id
    end
  end

  defp connect_device(encoded_token, range, firezone_id \\ Ecto.UUID.generate()) do
    attrs =
      %{
        "token" => encoded_token,
        "external_id" => firezone_id,
        "public_key" => generate_public_key()
      }
      |> Map.merge(range)

    connect(Socket, attrs, connect_info: build_connect_info(token: encoded_token))
  end

  defp connect_gateway(encoded_token, firezone_id) do
    attrs = %{"token" => encoded_token, "external_id" => firezone_id, "public_key" => generate_public_key()}

    connect(PortalAPI.Gateway.Socket, attrs, connect_info: build_connect_info(token: encoded_token))
  end
end
