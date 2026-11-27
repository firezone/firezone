defmodule Portal.Endpoint.AdmissionTest do
  use ExUnit.Case, async: true

  alias Portal.Endpoint.Admission

  defmodule TestEndpoint do
    use Phoenix.Endpoint, otp_app: :portal

    plug :ok

    def ok(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  setup do
    start_supervised!(
      {TestEndpoint,
       adapter: Bandit.PhoenixAdapter,
       server: true,
       http: [ip: {127, 0, 0, 1}, port: 0],
       secret_key_base: String.duplicate("a", 64)}
    )

    {:ok, server} = Bandit.PhoenixAdapter.bandit_pid(TestEndpoint, :http)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    %{server: server, port: port}
  end

  test "refuses new connections and keeps established ones after it stops", %{
    server: server,
    port: port
  } do
    {:ok, established} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    assert {:ok, "HTTP/1.1 200 OK" <> _} = request(established)

    listener = ThousandIsland.Server.listener_pid(server)
    {listen_socket, _span} = ThousandIsland.Listener.acceptor_info(listener, 1)
    listen_socket_ref = :erlang.monitor(:port, listen_socket)

    admission = start_supervised!({Admission, endpoint: TestEndpoint})

    :ok = GenServer.stop(admission)

    assert ThousandIsland.status(server) == :suspended
    assert_receive {:DOWN, ^listen_socket_ref, :port, ^listen_socket, _reason}

    assert {:ok, "HTTP/1.1 200 OK" <> _} = request(established)
  end

  test "does nothing when the endpoint is not running" do
    assert Admission.close(Portal.Endpoint.AdmissionTest.Stopped) == :ok
  end

  defp request(socket) do
    :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nhost: localhost\r\n\r\n")
    :gen_tcp.recv(socket, 0, 5_000)
  end
end
