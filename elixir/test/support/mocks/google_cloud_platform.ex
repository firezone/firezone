defmodule Portal.Mocks.GoogleCloudPlatform do
  @moduledoc """
  Test helpers for mocking Google Cloud Platform API responses using Req.Test.
  """

  alias Portal.GoogleCloudPlatform

  @doc """
  Sets up a Req.Test stub with the given expectations.

  Expectations are a list of tuples: `{method, path_pattern, status, response, opts}`
  where opts can include `:decode_json` (default true) to control JSON encoding.

  ## Example

      GoogleCloudPlatform.stub([
        {"GET", ~r|/instance/service-accounts/default/token|, 200, token_response()},
        {"GET", ~r|/compute/v1/projects/.*/aggregated/instances|, 200, instances_response()}
      ])
  """
  def stub(expectations) when is_list(expectations) do
    Req.Test.stub(GoogleCloudPlatform, fn conn ->
      method = conn.method
      path = conn.request_path

      case find_expectation(expectations, method, path, conn) do
        {:ok, {status, response, opts}} ->
          send_response(conn, status, response, opts)

        :not_found ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            404,
            JSON.encode!(%{"error" => "No mock expectation for #{method} #{path}"})
          )
      end
    end)
  end

  defp find_expectation(expectations, method, path, conn) do
    Enum.find_value(expectations, :not_found, fn
      {:dynamic_sign_blob, service_account_email, pattern} ->
        if method == "POST" and Regex.match?(pattern, path) do
          {:ok, body, _conn} = Plug.Conn.read_body(conn)
          %{"payload" => payload} = JSON.decode!(body)

          resp = %{
            "keyId" => Ecto.UUID.generate(),
            "signedBlob" => Portal.Crypto.hash(:md5, service_account_email <> payload)
          }

          {:ok, {200, resp, []}}
        else
          nil
        end

      {:capture_metrics, test_pid, pattern} ->
        if method == "POST" and Regex.match?(pattern, path) do
          {:ok, body, _conn} = Plug.Conn.read_body(conn)
          decoded_body = JSON.decode!(body)
          send(test_pid, {:metrics_request, conn, decoded_body})
          {:ok, {200, %{}, []}}
        else
          nil
        end

      {^method, %Regex{} = regex, status, response} ->
        if Regex.match?(regex, path), do: {:ok, {status, response, []}}, else: nil

      {^method, %Regex{} = regex, status, response, opts} ->
        if Regex.match?(regex, path), do: {:ok, {status, response, opts}}, else: nil

      {^method, expected_path, status, response} when expected_path == path ->
        {:ok, {status, response, []}}

      {^method, expected_path, status, response, opts} when expected_path == path ->
        {:ok, {status, response, opts}}

      _ ->
        nil
    end)
  end

  defp send_response(conn, status, response, opts) do
    if Keyword.get(opts, :raw, false) do
      conn
      |> Plug.Conn.send_resp(status, response)
    else
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(response))
    end
  end

  # Convenience functions for building expectations

  def mock_instance_metadata_token_endpoint(resp \\ nil) do
    resp =
      resp ||
        %{
          "access_token" => "GCP_ACCESS_TOKEN",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        }

    [{"GET", ~r|/instance/service-accounts/default/token|, 200, resp}]
  end

  def mock_instance_metadata_id_endpoint(id \\ Ecto.UUID.generate()) do
    [{"GET", ~r|/instance/id|, 200, id, raw: true}]
  end

  def mock_instance_metadata_zone_endpoint(zone \\ "projects/001001/zones/us-east-1") do
    [{"GET", ~r|/instance/zone|, 200, zone, raw: true}]
  end

  @doc """
  Creates a sign blob endpoint expectation.

  Note: When `resp` is nil, the signed blob is computed dynamically from the
  request body's payload. This requires using `stub_sign_blob/2` instead of
  the standard `stub/1` to properly capture the request body.
  """
  def mock_sign_blob_endpoint(service_account_email, resp \\ nil) do
    pattern = ~r|service_accounts/#{Regex.escape(service_account_email)}:signBlob|

    if resp do
      [{"POST", pattern, 200, resp}]
    else
      # Return a special marker that stub/1 will handle to read request body
      [{:dynamic_sign_blob, service_account_email, pattern}]
    end
  end

  def mock_instances_list_endpoint(resp \\ nil) do
    project_endpoint = "https://www.googleapis.com/compute/v1/projects/firezone-staging"

    resp =
      resp ||
        %{
          "kind" => "compute#instanceAggregatedList",
          "id" => "projects/firezone-staging/aggregated/instances",
          "items" => %{
            "zones/us-east1-c" => %{
              "warning" => %{
                "code" => "NO_RESULTS_ON_PAGE"
              }
            },
            "zones/us-east1-d" => %{
              "instances" => [
                %{
                  "kind" => "compute#instance",
                  "id" => "101389045528522181",
                  "creationTimestamp" => "2023-06-02T13:38:02.907-07:00",
                  "name" => "api-q3j6",
                  "tags" => %{
                    "items" => [
                      "app-api"
                    ],
                    "fingerprint" => "utkJlpAke8c="
                  },
                  "machineType" =>
                    "#{project_endpoint}/zones/us-east1-d/machineTypes/n1-standard-1",
                  "status" => "RUNNING",
                  "zone" => "#{project_endpoint}/zones/us-east1-d",
                  "networkInterfaces" => [
                    %{
                      "kind" => "compute#networkInterface",
                      "network" => "#{project_endpoint}/global/networks/firezone-staging",
                      "subnetwork" => "#{project_endpoint}/regions/us-east1/subnetworks/app",
                      "networkIP" => "10.128.0.43",
                      "name" => "nic0",
                      "fingerprint" => "_4XbqLiVdkI=",
                      "stackType" => "IPV4_ONLY"
                    }
                  ],
                  "disks" => [],
                  "metadata" => %{
                    "kind" => "compute#metadata",
                    "fingerprint" => "3mI-QpsQdDk=",
                    "items" => []
                  },
                  "serviceAccounts" => [
                    %{
                      "email" => "app-api@firezone-staging.iam.gserviceaccount.com",
                      "scopes" => [
                        "https://www.googleapis.com/auth/compute.readonly",
                        "https://www.googleapis.com/auth/logging.write",
                        "https://www.googleapis.com/auth/monitoring",
                        "https://www.googleapis.com/auth/servicecontrol",
                        "https://www.googleapis.com/auth/service.management.readonly",
                        "https://www.googleapis.com/auth/devstorage.read_only",
                        "https://www.googleapis.com/auth/trace.append"
                      ]
                    }
                  ],
                  "selfLink" => "#{project_endpoint}/zones/us-east1-d/instances/api-q3j6",
                  "scheduling" => %{
                    "onHostMaintenance" => "MIGRATE",
                    "automaticRestart" => true,
                    "preemptible" => false,
                    "provisioningModel" => "STANDARD"
                  },
                  "cpuPlatform" => "Intel Haswell",
                  "labels" => %{
                    "application" => "api",
                    "cluster_name" => "firezone",
                    "container-vm" => "cos-105-17412-101-13",
                    "managed_by" => "terraform",
                    "version" => "0-0-1"
                  },
                  "labelFingerprint" => "ISmB9O6lTvg=",
                  "startRestricted" => false,
                  "deletionProtection" => false,
                  "shieldedInstanceConfig" => %{
                    "enableSecureBoot" => false,
                    "enableVtpm" => true,
                    "enableIntegrityMonitoring" => true
                  },
                  "shieldedInstanceIntegrityPolicy" => %{
                    "updateAutoLearnPolicy" => true
                  },
                  "fingerprint" => "fK6yUz9ED6s=",
                  "lastStartTimestamp" => "2023-06-02T13:38:06.900-07:00"
                }
              ]
            },
            "zones/asia-northeast1-a" => %{
              "warning" => %{
                "code" => "NO_RESULTS_ON_PAGE"
              }
            }
          }
        }

    [{"GET", ~r|/compute/v1/projects/.*/aggregated/instances|, 200, resp}]
  end

  def mock_metrics_submit_endpoint do
    [{"POST", ~r|/v3/projects/.*/timeSeries|, 200, %{}}]
  end

  @doc """
  Creates a metrics submit endpoint expectation that captures and sends the request body
  back to the calling process.

  The test can use `assert_receive {:metrics_request, conn, body}` to verify the request.
  """
  def mock_metrics_submit_endpoint_with_capture(test_pid) do
    [{:capture_metrics, test_pid, ~r|/v3/projects/.*/timeSeries|}]
  end
end
