defmodule PortalAPI.Device.SocketTest do
  use PortalAPI.ChannelCase, async: true
  import PortalAPI.Device.Socket, except: [connect: 3]
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.IdentityFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures
  alias PortalAPI.Device.Socket

  @user_agent "Linux/6.1 firezone/1.7.0 (x86_64; 6.1.0)"
  @range %{"proto_min" => "5", "proto_max" => "5"}

  describe "connect/3" do
    test "refuses a binary that is not the unified one" do
      token = client_token_fixture()

      connect_info =
        build_connect_info(token: encode_token(token), user_agent: "Linux/6.1 headless-client/1.5.9")

      attrs =
        valid_client_attrs()
        |> Map.put(:public_key, generate_public_key())
        |> Map.merge(@range)
        |> stringify()

      assert connect(Socket, attrs, connect_info: connect_info) == {:error, :unsupported_client}
    end

    test "refuses a connect that leaves out its protocol range" do
      token = client_token_fixture()
      connect_info = build_connect_info(token: encode_token(token), user_agent: @user_agent)
      attrs = valid_client_attrs() |> Map.put(:public_key, generate_public_key()) |> stringify()

      assert connect(Socket, attrs, connect_info: connect_info) == {:error, :protocol_range_required}
    end

    test "a client token makes it that actor's device, with both halves of the protocol" do
      account = account_fixture()
      actor = actor_fixture(account: account)
      identity = identity_fixture(account: account, actor: actor)
      token = client_token_fixture(account: account, actor: actor, identity: identity)

      connect_info = build_connect_info(token: encode_token(token), user_agent: @user_agent)

      attrs =
        valid_client_attrs()
        |> Map.put(:public_key, generate_public_key())
        |> Map.merge(@range)
        |> stringify()

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert %Portal.Device{type: :client} = device = socket.assigns.device
      assert device.actor_id == actor.id
      assert device.proto_range == %{min: 5, max: 5}
      assert socket.assigns.subject.credential.id == token.id
    end

    test "a gateway token makes it that gateway, with the account's infrastructure actor" do
      account = account_fixture()
      site = site_fixture(account: account)
      token = gateway_token_fixture(account: account, site: site)

      connect_info = build_connect_info(token: encode_gateway_token(token), user_agent: @user_agent)

      attrs =
        valid_gateway_attrs()
        |> Map.merge(@range)
        |> stringify()

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert %Portal.Device{type: :gateway} = device = socket.assigns.device
      assert device.site_id == site.id
      assert device.actor_id == socket.assigns.subject.actor.id
      assert socket.assigns.subject.actor.type == :service_account
      assert socket.assigns.token_id == token.id
    end

    test "a gateway reconnecting while its old connection lingers is not refused" do
      account = account_fixture()
      site = site_fixture(account: account)
      gateway = gateway_fixture(account: account, site: site)
      token = gateway_token_fixture(gateway: gateway)

      :ok = Portal.PG.register(gateway.id)

      connect_info = build_connect_info(token: encode_gateway_token(token), user_agent: @user_agent)

      attrs =
        valid_gateway_attrs(%{firezone_id: gateway.firezone_id})
        |> Map.merge(@range)
        |> stringify()

      assert {:ok, socket} = connect(Socket, attrs, connect_info: connect_info)
      assert socket.assigns.device.id == gateway.id
    end
  end

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
