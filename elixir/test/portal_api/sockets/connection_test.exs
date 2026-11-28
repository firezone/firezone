defmodule PortalAPI.Sockets.ConnectionTest do
  use PortalAPI.ChannelCase, async: true
  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DeviceFixtures
  import Portal.GroupFixtures
  import Portal.MembershipFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SiteFixtures
  import Portal.TokenFixtures

  alias Portal.{PG, Presence}
  alias PortalAPI.WebSocketClient

  # Serves the API endpoint over a real listener. The connection process takes the test process
  # as its caller, for the sandbox, the config overrides and the test queues.
  defmodule EndpointPlug do
    def init(opts), do: opts

    def call(conn, owner) do
      Process.put(:"$callers", [owner])
      PortalAPI.Endpoint.call(conn, PortalAPI.Endpoint.init([]))
    end
  end

  setup do
    for queue <- [:client_session_queue, :gateway_session_queue, :policy_authorization_queue] do
      Portal.Config.put_env_override(queue, name: {:via, Registry, {Portal.Test.QueueRegistry, {self(), queue}}})
    end

    for opts <- [
          PortalAPI.Client.Socket.client_session_queue_opts(),
          PortalAPI.Gateway.Socket.gateway_session_queue_opts(),
          PortalAPI.Client.Channel.policy_authorization_queue_opts()
        ] do
      start_supervised!({Portal.Queue, Keyword.merge(opts, callers: [self()], flush_on_terminate: false)})
    end

    server =
      start_supervised!(
        {Bandit, plug: {EndpointPlug, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    account = account_fixture()
    actor = actor_fixture(type: :account_admin_user, account: account)
    group = group_fixture(account: account)
    membership_fixture(account: account, actor: actor, group: group)
    site = site_fixture(account: account)

    %{port: port, account: account, actor: actor, group: group, site: site}
  end

  describe "/client/v5" do
    test "sends init as a bare event and tracks the client's presence", ctx do
      {ws, firezone_id} = connect_client(ctx)

      assert {:ok, %{"interface" => _interface}} = WebSocketClient.recv_message(ws, "init")

      client_id = client_id(firezone_id)
      [pid] = PG.members(client_id)
      assert pid in PortalAPI.Client.V5.Socket.connections()
      assert client_id in Presence.Devices.online_ids(ctx.account.id)

      WebSocketClient.close(ws)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      refute client_id in Presence.Devices.online_ids(ctx.account.id)
    end

    test "answers WebSocket pings", ctx do
      {ws, _firezone_id} = connect_client(ctx)
      {:ok, _init} = WebSocketClient.recv_message(ws, "init")

      :ok = WebSocketClient.send_ping(ws, "keepalive")

      assert WebSocketClient.recv_control(ws) == {:pong, "keepalive"}
    end

    test "refuses an invalid token with problem details", ctx do
      assert {:error, 401, headers, body} =
               WebSocketClient.connect(ctx.port, "/client/v5/websocket?" <> URI.encode_query(client_params()), [
                 {"x-authorization", "Bearer invalid-#{System.unique_integer([:positive])}"}
               ])

      assert {"content-type", "application/problem+json" <> _} = List.keyfind(headers, "content-type", 0)
      assert %{"code" => "invalid_token"} = JSON.decode!(body)
    end

    test "ignores messages of clients before 1.4", ctx do
      {ws, _firezone_id} = connect_client(ctx)
      {:ok, _init} = WebSocketClient.recv_message(ws, "init")

      log =
        capture_log(fn ->
          :ok = WebSocketClient.send_message(ws, "prepare_connection", %{"resource_id" => Ecto.UUID.generate()})
          :ok = WebSocketClient.send_ping(ws, "after")
          assert WebSocketClient.recv_control(ws) == {:pong, "after"}
        end)

      assert log =~ "Unknown client message"
    end

    test "closes with 1007 on a text frame that is not a message", ctx do
      {ws, _firezone_id} = connect_client(ctx)
      {:ok, _init} = WebSocketClient.recv_message(ws, "init")

      :ok = WebSocketClient.send_text(ws, ~s({"topic":"client","event":"phx_join"}))

      assert WebSocketClient.recv_control(ws) == {:close, 1007}
    end

    test "closes with 1003 on a binary frame", ctx do
      {ws, _firezone_id} = connect_client(ctx)
      {:ok, _init} = WebSocketClient.recv_message(ws, "init")

      :ok = WebSocketClient.send_binary(ws, <<1, 2, 3>>)

      assert WebSocketClient.recv_control(ws) == {:close, 1003}
    end

    test "sends disconnect before it closes the session", ctx do
      {ws, firezone_id} = connect_client(ctx)
      {:ok, _init} = WebSocketClient.recv_message(ws, "init")
      PG.deliver(client_id(firezone_id), :disconnect)

      assert {:ok, %{"reason" => "token_expired"}} = WebSocketClient.recv_message(ws, "disconnect")
      assert WebSocketClient.recv_control(ws) == {:close, 1000}
    end

    test "closes with 1012 when the node drains", ctx do
      {ws, firezone_id} = connect_client(ctx)
      {:ok, _init} = WebSocketClient.recv_message(ws, "init")
      [pid] = PG.members(client_id(firezone_id))

      send(pid, %Phoenix.Socket.Broadcast{event: "phx_drain"})

      assert WebSocketClient.recv_control(ws) == {:close, 1012}
    end
  end

  describe "/gateway/v4" do
    test "sends init and refuses a second connection of the same gateway", ctx do
      gateway_token = gateway_token_fixture(account: ctx.account, site: ctx.site)
      params = gateway_params()

      {:ok, ws} = connect_gateway(ctx, gateway_token, params)
      assert {:ok, %{"interface" => _interface}} = WebSocketClient.recv_message(ws, "init")

      assert {:error, 409, _headers, body} = connect_gateway(ctx, gateway_token, params)
      assert %{"code" => "gateway_already_connected"} = JSON.decode!(body)
    end

    test "authorizes a client on /client/v5", ctx do
      resource = cidr_resource_fixture(account: ctx.account, site: ctx.site, address: "10.0.0.0/24")
      policy_fixture(account: ctx.account, group: ctx.group, resource: resource)

      gateway_token = gateway_token_fixture(account: ctx.account, site: ctx.site)
      {:ok, gateway_ws} = connect_gateway(ctx, gateway_token, gateway_params())
      {:ok, _init} = WebSocketClient.recv_message(gateway_ws, "init")

      {client_ws, _firezone_id} = connect_client(ctx)
      {:ok, _init} = WebSocketClient.recv_message(client_ws, "init")

      :ok =
        WebSocketClient.send_message(client_ws, "request_access", %{
          "resource_ids" => [resource.id],
          "connected_gateway_ids" => []
        })

      assert {:ok, %{"ref" => ref, "resource" => %{"id" => resource_id}}} =
               WebSocketClient.recv_message(gateway_ws, "create_authorization")

      assert resource_id == resource.id

      :ok = WebSocketClient.send_message(gateway_ws, "authorization_created", %{"ref" => ref})

      assert {:ok, %{"resource_id" => ^resource_id}} =
               WebSocketClient.recv_message(client_ws, "authorization_created")
    end
  end

  defp connect_client(ctx) do
    token = client_token_fixture(account: ctx.account, actor: ctx.actor) |> encode_token()
    params = client_params()

    {:ok, ws} =
      WebSocketClient.connect(ctx.port, "/client/v5/websocket?" <> URI.encode_query(params), [
        {"x-authorization", "Bearer #{token}"},
        {"user-agent", "Mac OS/15.0 connlib/1.5.0"}
      ])

    {ws, params["external_id"]}
  end

  defp connect_gateway(ctx, gateway_token, params) do
    WebSocketClient.connect(ctx.port, "/gateway/v4/websocket?" <> URI.encode_query(params), [
      {"x-authorization", "Bearer #{encode_gateway_token(gateway_token)}"},
      {"user-agent", "Linux/6.8 connlib/1.5.0"}
    ])
  end

  defp client_id(firezone_id) do
    Repo.get_by!(Portal.Device, firezone_id: firezone_id, type: :client).id
  end

  defp client_params do
    %{"external_id" => "client_#{System.unique_integer([:positive])}", "public_key" => generate_public_key()}
  end

  defp gateway_params do
    %{"external_id" => "gateway_#{System.unique_integer([:positive])}", "public_key" => generate_public_key()}
  end
end
