defmodule PortalAPI.OTLPMetricsControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures

  alias Portal.Azure.ManagedIdentity
  alias Portal.OTLP.MetricsExporter
  alias Portal.MetricsToken

  @moduletag capture_log: true

  @pb :opentelemetry_exporter_metrics_service_pb

  setup %{conn: conn} do
    Req.Test.verify_on_exit!()

    Req.Test.stub(ManagedIdentity, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "azure-token",
        "expires_on" => System.system_time(:second) + 3600
      })
    end)

    %{account: account_fixture(), conn: %{conn | remote_ip: unique_ip()}}
  end

  describe "create/2" do
    test "forwards allowed metrics with the token's account identity", %{conn: conn, account: account} do
      test_pid = self()

      Req.Test.expect(MetricsExporter, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:forwarded, Plug.Conn.get_req_header(conn, "authorization"), body})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      body =
        export_request(
          [
            sum("connlib.network.packets", [
              attribute("network.type", "ipv4"),
              attribute("firezone.account.id", "spoofed")
            ]),
            sum("not.allowed")
          ],
          [
            attribute("service.name", "firezone-gateway"),
            attribute("firezone.account.id", "spoofed"),
            attribute("firezone.account.slug", "spoofed"),
            attribute("host.name", "laptop")
          ]
        )

      conn = conn |> authorize(account, ["connlib.network.packets"]) |> post_metrics(body)

      assert response(conn, 200) == @pb.encode_msg(%{}, :export_metrics_service_response)
      assert ["application/x-protobuf"] = get_resp_header(conn, "content-type")

      assert_receive {:forwarded, ["Bearer azure-token"], forwarded}
      [resource_metrics] = decode(forwarded).resource_metrics

      assert attributes(resource_metrics.resource) == %{
               "firezone.account.id" => account.id,
               "firezone.account.slug" => account.slug,
               "service.name" => "firezone-gateway"
             }

      [%{metrics: [metric]}] = resource_metrics.scope_metrics
      assert metric.name == "connlib.network.packets"

      {:sum, %{data_points: [point]}} = metric.data
      assert attributes(point) == %{"network.type" => "ipv4"}
      assert point.exemplars == []
    end

    test "forwards every metric for a token allowing all", %{conn: conn, account: account} do
      test_pid = self()

      Req.Test.expect(MetricsExporter, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:forwarded, body})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      body = export_request([sum("a"), sum("b")])

      conn = conn |> authorize(account, ["*"]) |> post_metrics(body)

      assert response(conn, 200)
      assert_receive {:forwarded, forwarded}
      [%{scope_metrics: [%{metrics: metrics}]}] = decode(forwarded).resource_metrics
      assert Enum.map(metrics, & &1.name) == ["a", "b"]
    end

    test "forwards nothing for a token allowing no metrics", %{conn: conn, account: account} do
      Req.Test.stub(MetricsExporter, fn _conn -> flunk("must not forward") end)

      conn =
        conn
        |> authorize(account, [])
        |> post_metrics(export_request([sum("connlib.network.packets")]))

      assert response(conn, 200)
    end

    test "records ingested data points by outcome", %{conn: conn, account: account} do
      test_pid = self()
      handler_id = "test-otlp-ingest-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:portal, :otlp_ingest, :data_points],
        fn _event, %{count: count}, %{outcome: outcome}, _config ->
          send(test_pid, {:data_points, self(), outcome, count})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.expect(MetricsExporter, &Plug.Conn.send_resp(&1, 200, ""))
      Req.Test.expect(MetricsExporter, &Plug.Conn.send_resp(&1, 400, ""))

      body = export_request([sum("a"), sum("b"), sum("c")])

      assert conn |> authorize(account, ["a", "b"]) |> post_metrics(body) |> response(200)
      assert_receive {:data_points, ^test_pid, :filtered, 1}
      assert_receive {:data_points, ^test_pid, :forwarded, 2}

      assert conn |> recycle() |> authorize(account) |> post_metrics(body) |> response(500)
      assert_receive {:data_points, ^test_pid, :filtered, 0}
      assert_receive {:data_points, ^test_pid, :failed, 3}
    end

    test "returns 503 when the upstream fails transiently", %{conn: conn, account: account} do
      Req.Test.expect(MetricsExporter, &Plug.Conn.send_resp(&1, 503, ""))

      conn = conn |> authorize(account) |> post_metrics(export_request([sum("tunnel.error")]))

      assert response(conn, 503)
    end

    test "returns 500 when the upstream rejects the request", %{conn: conn, account: account} do
      Req.Test.expect(MetricsExporter, &Plug.Conn.send_resp(&1, 400, ""))

      conn = conn |> authorize(account) |> post_metrics(export_request([sum("tunnel.error")]))

      assert response(conn, 500)
    end
  end

  describe "request validation" do
    test "returns 401 without a token", %{conn: conn} do
      conn = post_metrics(conn, export_request([]))

      assert response(conn, 401)
    end

    test "returns 401 for an invalid token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-jwt")
        |> post_metrics(export_request([]))

      assert response(conn, 401)
    end

    test "returns 415 for a non-protobuf body", %{conn: conn, account: account} do
      conn =
        conn
        |> authorize(account)
        |> put_req_header("content-type", "application/json")
        |> post("/v1/metrics", "{}")

      assert response(conn, 415)
    end

    test "returns 415 for a compressed body", %{conn: conn, account: account} do
      conn =
        conn
        |> authorize(account)
        |> put_req_header("content-encoding", "gzip")
        |> post_metrics(:zlib.gzip(export_request([])))

      assert response(conn, 415)
    end

    test "returns 400 for an undecodable body", %{conn: conn, account: account} do
      conn = conn |> authorize(account) |> post_metrics(<<1, 2, 3, 255>>)

      assert response(conn, 400)
    end

    test "returns 400 for a body with invalid UTF-8 strings", %{conn: conn, account: account} do
      body =
        [sum("a")]
        |> export_request([attribute("service.name", "placeholder")])
        |> :binary.replace("placeholder", :binary.copy(<<0xFF>>, 11))

      conn = conn |> authorize(account) |> post_metrics(body)

      assert response(conn, 400)
    end

    test "returns 413 for an oversized body", %{conn: conn, account: account} do
      conn = conn |> authorize(account) |> post_metrics(:binary.copy(<<0>>, 1_000_001))

      assert response(conn, 413)
    end

    test "returns 404 when forwarding is not configured", %{conn: conn, account: account} do
      Portal.Config.put_env_override(:otlp_metrics_endpoint, false)

      conn = conn |> authorize(account) |> post_metrics(export_request([]))

      assert response(conn, 404)
    end
  end

  describe "rate limiting" do
    test "limits requests per source IP", %{conn: conn, account: account} do
      limit(:ip)

      assert conn |> authorize(account) |> post_metrics(export_request([])) |> response(200)

      conn = conn |> authorize(account) |> post_metrics(export_request([]))

      assert response(conn, 429)
      assert [_retry_after] = get_resp_header(conn, "retry-after")
    end

    test "limits requests per account", %{conn: conn, account: account} do
      limit(:account)

      assert conn |> authorize(account) |> post_metrics(export_request([])) |> response(200)

      conn =
        %{conn | remote_ip: unique_ip()} |> authorize(account) |> post_metrics(export_request([]))

      assert response(conn, 429)
      assert [_retry_after] = get_resp_header(conn, "retry-after")

      other_account = account_fixture()

      assert conn
             |> recycle()
             |> Map.put(:remote_ip, unique_ip())
             |> authorize(other_account)
             |> post_metrics(export_request([]))
             |> response(200)
    end
  end

  defp authorize(conn, account, metrics \\ ["*"]) do
    put_req_header(conn, "authorization", "Bearer " <> MetricsToken.mint(account, metrics))
  end

  defp post_metrics(conn, body) do
    conn
    |> put_req_header("content-type", "application/x-protobuf")
    |> post("/v1/metrics", body)
  end

  defp export_request(metrics, resource_attributes \\ []) do
    @pb.encode_msg(
      %{
        resource_metrics: [
          %{
            resource: %{attributes: resource_attributes},
            scope_metrics: [%{scope: %{name: "connlib", version: "1.0.0"}, metrics: metrics}]
          }
        ]
      },
      :export_metrics_service_request
    )
  end

  defp sum(name, attributes \\ []) do
    point = %{
      attributes: attributes,
      time_unix_nano: 1,
      value: {:as_int, 1},
      exemplars: [%{filtered_attributes: [attribute("user", "secret")], value: {:as_int, 1}}]
    }

    %{
      name: name,
      data:
        {:sum,
         %{
           data_points: [point],
           aggregation_temporality: :AGGREGATION_TEMPORALITY_CUMULATIVE,
           is_monotonic: true
         }}
    }
  end

  defp attribute(key, value), do: %{key: key, value: %{value: {:string_value, value}}}

  defp attributes(%{attributes: attributes}) do
    Map.new(attributes, fn %{key: key, value: %{value: {:string_value, value}}} -> {key, value} end)
  end

  defp decode(body), do: @pb.decode_msg(body, :export_metrics_service_request)

  defp limit(by) do
    Portal.Config.put_env_override(
      PortalAPI.Plugs.MetricsRateLimit,
      Keyword.put(
        Portal.Config.fetch_env!(:portal, PortalAPI.Plugs.MetricsRateLimit),
        by,
        refill_rate: 1,
        capacity: 1
      )
    )
  end

  defp unique_ip do
    counter = System.unique_integer([:positive, :monotonic])

    {10, rem(div(counter, 65_536), 256), rem(div(counter, 256), 256), rem(counter, 254) + 1}
  end
end
