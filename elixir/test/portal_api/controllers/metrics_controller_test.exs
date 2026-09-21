defmodule PortalAPI.MetricsControllerTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures

  alias Portal.MetricsToken

  setup do
    %{account: account_fixture()}
  end

  defp authorize(conn, account) do
    token = MetricsToken.mint(account, Ecto.UUID.generate(), Ecto.UUID.generate())
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp post_metrics(conn, body) do
    post(conn, "/v1/metrics", body)
  end

  # An OTLP/JSON ExportMetricsServiceRequest carrying a single counter: 64-bit
  # values and timestamps are decimal strings, keys are lowerCamelCase.
  defp export_request do
    %{
      "resourceMetrics" => [
        %{
          "resource" => %{
            "attributes" => [
              %{"key" => "service.name", "value" => %{"stringValue" => "firezone-gateway"}}
            ]
          },
          "scopeMetrics" => [
            %{
              "scope" => %{"name" => "firezone_gateway", "version" => "1.5.0"},
              "metrics" => [
                %{
                  "name" => "firezone.gateway.packets",
                  "unit" => "{packet}",
                  "sum" => %{
                    "dataPoints" => [
                      %{
                        "startTimeUnixNano" => "1758412800000000000",
                        "timeUnixNano" => "1758412860000000000",
                        "asInt" => "1234",
                        "attributes" => [
                          %{"key" => "direction", "value" => %{"stringValue" => "rx"}}
                        ]
                      }
                    ],
                    "aggregationTemporality" => 2,
                    "isMonotonic" => true
                  }
                }
              ]
            }
          ]
        }
      ]
    }
  end

  describe "create/2" do
    test "accepts an export request", %{conn: conn, account: account} do
      conn = conn |> authorize(account) |> post_metrics(export_request())

      assert json_response(conn, 200) == %{}
    end

    test "accepts an export request with no data points", %{conn: conn, account: account} do
      conn = conn |> authorize(account) |> post_metrics(%{})

      assert json_response(conn, 200) == %{}
    end

    test "accepts metric kinds it does not handle", %{conn: conn, account: account} do
      body = %{
        "resourceMetrics" => [
          %{
            "scopeMetrics" => [
              %{
                "metrics" => [
                  %{
                    "name" => "firezone.gateway.latency",
                    "histogram" => %{"dataPoints" => [%{"count" => "3", "sum" => 1.5}]}
                  }
                ]
              }
            ]
          }
        ]
      }

      conn = conn |> authorize(account) |> post_metrics(body)

      assert json_response(conn, 200) == %{}
    end

    test "returns 400 when the envelope is malformed", %{conn: conn, account: account} do
      conn = conn |> authorize(account) |> post_metrics(%{"resourceMetrics" => "nope"})

      assert %{"status" => 400, "detail" => "Expected an OTLP ExportMetricsServiceRequest"} =
               json_response(conn, 400)
    end

    test "returns 400 when a metric has no name", %{conn: conn, account: account} do
      body = %{
        "resourceMetrics" => [
          %{"scopeMetrics" => [%{"metrics" => [%{"sum" => %{"dataPoints" => []}}]}]}
        ]
      }

      conn = conn |> authorize(account) |> post_metrics(body)

      assert %{"status" => 400} = json_response(conn, 400)
    end
  end

  describe "create/2 request authentication" do
    test "rejects an unauthenticated malformed JSON request before decoding it", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/v1/metrics", "{")

      assert %{"status" => 401, "detail" => "Authentication credentials were missing or invalid."} =
               json_response(conn, 401)
    end

    test "returns 401 when the Authorization header is missing", %{conn: conn} do
      conn = post_metrics(conn, export_request())

      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "returns 401 when the token signature is tampered", %{conn: conn, account: account} do
      token = MetricsToken.mint(account, Ecto.UUID.generate(), Ecto.UUID.generate())

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token <> "x")
        |> post_metrics(export_request())

      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "returns 401 when the token is signed with the wrong account key", %{conn: conn} do
      account = account_fixture()
      impostor = %{account | ingest_signing_key: :crypto.strong_rand_bytes(32)}
      token = MetricsToken.mint(impostor, Ecto.UUID.generate(), Ecto.UUID.generate())

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> post_metrics(export_request())

      assert %{"status" => 401} = json_response(conn, 401)
    end

    test "returns 401 when the token is expired", %{conn: conn, account: account} do
      expired =
        account.ingest_signing_key
        |> JOSE.JWK.from_oct()
        |> JOSE.JWT.sign(%{"alg" => "HS256"}, %{
          "account_id" => account.id,
          "gateway_id" => Ecto.UUID.generate(),
          "site_id" => Ecto.UUID.generate(),
          "exp" => DateTime.to_unix(DateTime.utc_now()) - 1
        })
        |> JOSE.JWS.compact()
        |> elem(1)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> expired)
        |> post_metrics(export_request())

      assert %{"status" => 401} = json_response(conn, 401)
    end
  end
end
