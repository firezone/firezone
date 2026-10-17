defmodule PortalAPI.MetricsControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.RepoQueryHelpers
  import Portal.SiteFixtures

  @protobuf :opentelemetry_exporter_metrics_service_pb
  @url "https://telemetry.firezone.dev/v1/metrics"
  @dce "https://dce.monitor.test/v1/metrics"

  setup do
    Portal.Config.put_env_override(:portal, :metrics_dce_endpoint, @dce)

    Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "monitor-token",
        "expires_on" => Integer.to_string(System.system_time(:second) + 3600)
      })
    end)

    account = account_fixture()
    site = site_fixture(account: account)
    gateway_id = Ecto.UUID.generate()
    {:ok, token} = Portal.MetricsToken.mint(account, gateway_id, site)

    %{account: account, site: site, gateway_id: gateway_id, token: token}
  end

  defp export_request(resource_attributes) do
    resource_metrics = %{
      scope_metrics: [
        %{
          scope: %{name: "connlib"},
          metrics: [
            %{
              name: "flow_logs.report.errors",
              data:
                {:sum,
                 %{
                   data_points: [%{value: {:as_int, 3}}],
                   aggregation_temporality: :AGGREGATION_TEMPORALITY_DELTA,
                   is_monotonic: true
                 }}
            }
          ]
        }
      ]
    }

    resource_metrics =
      if resource_attributes,
        do: Map.put(resource_metrics, :resource, %{attributes: resource_attributes}),
        else: resource_metrics

    @protobuf.encode_msg(
      %{resource_metrics: [resource_metrics, resource_metrics]},
      :export_metrics_service_request
    )
  end

  defp string_attribute(key, value), do: %{key: key, value: %{value: {:string_value, value}}}

  defp post_report(conn, token, body, url \\ @url) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/x-protobuf")
    |> post(url, body)
  end

  defp forward_to(test_pid) do
    Req.Test.stub(Portal.Azure.Monitor, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:forwarded, conn, body})
      Plug.Conn.send_resp(conn, 204, "")
    end)
  end

  defp resource_attributes(resource_metrics) do
    Map.new(resource_metrics.resource.attributes, fn %{key: key, value: %{value: {_, value}}} ->
      {key, value}
    end)
  end

  test "forwards the report as protobuf, attributed from the token", %{
    conn: conn,
    account: account,
    site: site,
    gateway_id: gateway_id,
    token: token
  } do
    forward_to(self())

    conn = post_report(conn, token, export_request(nil))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/x-protobuf; charset=utf-8"]
    assert @protobuf.decode_msg(conn.resp_body, :export_metrics_service_response) == %{}

    assert_received {:forwarded, forwarded, body}
    assert forwarded.method == "POST"
    assert forwarded.host == "dce.monitor.test"
    assert forwarded.request_path == "/v1/metrics"
    assert Plug.Conn.get_req_header(forwarded, "content-type") == ["application/x-protobuf"]
    assert Plug.Conn.get_req_header(forwarded, "authorization") == ["Bearer monitor-token"]

    %{resource_metrics: [first, second]} =
      @protobuf.decode_msg(body, :export_metrics_service_request)

    expected = %{
      "firezone.account.id" => account.id,
      "firezone.account.slug" => account.slug,
      "firezone.gateway.id" => gateway_id,
      "firezone.site.id" => site.id,
      "firezone.site.name" => site.name
    }

    assert resource_attributes(first) == expected
    assert resource_attributes(second) == expected

    assert [%{metrics: [%{name: "flow_logs.report.errors", data: {:sum, sum}}]}] =
             first.scope_metrics

    assert [%{value: {:as_int, 3}}] = sum.data_points
  end

  test "overwrites the resource the gateway sent", %{conn: conn, token: token} do
    forward_to(self())

    body =
      export_request([
        string_attribute("firezone.account.id", Ecto.UUID.generate()),
        string_attribute("service.name", "impostor")
      ])

    conn = post_report(conn, token, body)

    assert conn.status == 200
    assert_received {:forwarded, _conn, forwarded}

    for resource_metrics <- @protobuf.decode_msg(forwarded, :export_metrics_service_request).resource_metrics do
      attributes = resource_attributes(resource_metrics)
      refute Map.has_key?(attributes, "service.name")
      assert attributes["firezone.account.id"] == JOSE.JWT.peek_payload(token).fields["account_id"]
    end
  end

  test "makes no database query", %{conn: conn, token: token} do
    forward_to(self())

    assert capture_queries_on_all_repos(fn ->
             assert post_report(conn, token, export_request(nil)).status == 200
           end) == []
  end

  test "returns 400 for a body that is not an export request", %{conn: conn, token: token} do
    conn = post_report(conn, token, <<0xFF, 0xFF, 0xFF>>)

    assert %{"status" => 400} = JSON.decode!(conn.resp_body)
    refute_received {:forwarded, _conn, _body}
  end

  test "returns 401 before reading the body without a valid token", %{conn: conn} do
    conn = post_report(conn, "not-a-jwt", <<0xFF>>)

    assert conn.status == 401
  end

  test "returns a 5xx when Azure Monitor fails, so the gateway retries", %{
    conn: conn,
    token: token
  } do
    Req.Test.stub(Portal.Azure.Monitor, &Plug.Conn.send_resp(&1, 503, ""))

    conn = post_report(conn, token, export_request(nil))

    assert conn.status == 502
  end

  test "returns a 5xx when Azure Monitor times out", %{conn: conn, token: token} do
    Req.Test.stub(Portal.Azure.Monitor, &Req.Test.transport_error(&1, :timeout))

    conn = post_report(conn, token, export_request(nil))

    assert conn.status == 504
  end

  test "returns a 5xx while no data collection endpoint is configured", %{
    conn: conn,
    token: token
  } do
    Portal.Config.put_env_override(:portal, :metrics_dce_endpoint, nil)

    conn = post_report(conn, token, export_request(nil))

    assert conn.status == 503
  end

  test "is only served on the metrics host", %{conn: conn, token: token} do
    forward_to(self())

    conn = post_report(conn, token, export_request(nil), "https://api.firezone.dev/v1/metrics")

    assert conn.status == 404
    refute_received {:forwarded, _conn, _body}
  end
end
