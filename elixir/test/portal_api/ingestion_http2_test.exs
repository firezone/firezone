defmodule PortalAPI.IngestionHTTP2Test do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.FlowLogFixtures

  alias Mint.HTTP2

  # Configure only the test listener and sandbox ownership. Dispatch, routing,
  # authentication, parsing, and error rendering all use the real endpoints.
  defmodule EndpointPlug do
    def init(opts), do: opts

    def call(conn, {owner, ip}) do
      Ecto.Adapters.SQL.Sandbox.allow(Portal.Repo, owner, self())
      Portal.Config.put_env_override(:portal, :flow_logs_api_url, "http://127.0.0.1")
      Portal.Config.put_env_override(:portal, Portal.Endpoint, https: nil)

      conn
      |> Map.put(:remote_ip, ip)
      |> Portal.Endpoint.call(Portal.Endpoint.init([]))
    end
  end

  setup do
    account = account_fixture()
    token = Portal.FlowLogToken.mint(account, flow_log_token_claims(), DateTime.utc_now())
    counter = System.unique_integer([:positive, :monotonic])
    ip = {10, rem(div(counter, 65_536), 256), rem(div(counter, 256), 256), rem(counter, 256)}

    server = start_supervised!({Bandit,
      plug: {EndpointPlug, {self(), ip}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    {:ok, conn} = HTTP2.connect(:http, "127.0.0.1", port, mode: :passive)

    on_exit(fn -> HTTP2.close(conn) end)
    %{http: conn, token: token}
  end

  for {name, body} <- [
    {"malformed JSON", "{"},
    {"invalid UTF-8", <<255>>},
    {"truncated array", "[1,"}
  ] do
    test "authenticated #{name} returns 400 and preserves the HTTP/2 connection", ctx do
      {conn, response} = request(ctx.http, ctx.token, unquote(body))
      assert_problem(response, 400)
      assert_next_request(conn, ctx.token)
    end
  end

  test "authenticated oversized body returns 413 and preserves the HTTP/2 connection", ctx do
    {conn, response} = request(ctx.http, ctx.token, String.duplicate(" ", 10_000_001))
    assert_problem(response, 413)
    assert_next_request(conn, ctx.token)
  end

  test "a body at the 10 MB limit is accepted", ctx do
    json = ~s({"flow_logs":[]})
    body = json <> String.duplicate(" ", 10_000_000 - byte_size(json))
    {conn, response} = request(ctx.http, ctx.token, body)
    assert response.status == 200
    assert JSON.decode!(response.body) == %{"data" => %{"status" => "ok"}}
    assert_next_request(conn, ctx.token)
  end

  test "unauthenticated malformed JSON is rejected before parsing", ctx do
    {conn, response} = request(ctx.http, nil, "{")
    assert_problem(response, 401)
    assert_next_request(conn, ctx.token)
  end

  for body <- ["", "null", "[]", "{}", ~s({"flow_logs":false})] do
    test "valid JSON shape #{inspect(body)} reaches controller validation", ctx do
      {conn, response} = request(ctx.http, ctx.token, unquote(body))
      assert_problem(response, 400)
      assert JSON.decode!(response.body)["detail"] == "Expected a \"flow_logs\" array"
      assert_next_request(conn, ctx.token)
    end
  end

  defp assert_next_request(conn, token) do
    {conn, response} = request(conn, token, ~s({"flow_logs":[]}))
    assert response.status == 200
    assert JSON.decode!(response.body) == %{"data" => %{"status" => "ok"}}
    assert HTTP2.open?(conn)
  end

  defp assert_problem(response, status) do
    assert response.status == status
    assert {"content-type", "application/problem+json; charset=utf-8"} in response.headers
    assert JSON.decode!(response.body)["status"] == status
  end

  defp request(conn, token, body) do
    headers = [{"content-type", "application/json"}, {"content-length", to_string(byte_size(body))}]
    headers = if token, do: [{"authorization", "Bearer " <> token} | headers], else: headers
    {:ok, conn, ref} = HTTP2.request(conn, "POST", "/ingestion/flow_logs", headers, :stream)
    {conn, events} = upload(conn, ref, body, [])
    {conn, events} = receive_response(conn, ref, events)

    response = Enum.reduce(events, %{status: nil, headers: [], body: ""}, fn
      {:status, ^ref, status}, response -> %{response | status: status}
      {:headers, ^ref, headers}, response -> %{response | headers: response.headers ++ headers}
      {:data, ^ref, data}, response -> %{response | body: response.body <> data}
      _, response -> response
    end)
    {conn, response}
  end

  defp upload(conn, ref, "", events) do
    {:ok, conn} = HTTP2.stream_request_body(conn, ref, :eof)
    {conn, events}
  end

  defp upload(conn, ref, body, events) do
    size = min(HTTP2.get_window_size(conn, :connection), HTTP2.get_window_size(conn, {:request, ref}))

    if size > 0 do
      size = min(size, byte_size(body))
      chunk = binary_part(body, 0, size)
      rest = binary_part(body, size, byte_size(body) - size)
      {:ok, conn} = HTTP2.stream_request_body(conn, ref, chunk)
      upload(conn, ref, rest, events)
    else
      {:ok, conn, received} = HTTP2.recv(conn, 0, 5_000)
      upload(conn, ref, body, events ++ received)
    end
  end

  defp receive_response(conn, ref, events) do
    if {:done, ref} in events do
      {conn, events}
    else
      {:ok, conn, received} = HTTP2.recv(conn, 0, 5_000)
      receive_response(conn, ref, events ++ received)
    end
  end
end
