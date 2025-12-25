defmodule Portal.Mocks.GoogleCloudPlatform do
  def override_endpoint_url(endpoint, url) do
    config = Portal.Config.fetch_env!(:portal, Portal.GoogleCloudPlatform)
    config = Keyword.put(config, endpoint, url)
    Portal.Config.put_env_override(:portal, Portal.GoogleCloudPlatform, config)
  end

  def mock_instance_metadata_id_endpoint(bypass, id \\ Ecto.UUID.generate()) do
    token_endpoint_path = "/instance/id"

    test_pid = self()

    Bypass.stub(bypass, "GET", token_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, id)
    end)

    override_endpoint_url(:metadata_endpoint_url, "http://localhost:#{bypass.port}/")

    bypass
  end

  def mock_instance_metadata_zone_endpoint(bypass, zone \\ "projects/001001/zones/us-east-1") do
    token_endpoint_path = "/instance/zone"

    test_pid = self()

    Bypass.stub(bypass, "GET", token_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, zone)
    end)

    override_endpoint_url(:metadata_endpoint_url, "http://localhost:#{bypass.port}/")

    bypass
  end

  def mock_instance_metadata_token_endpoint(bypass, resp \\ nil) do
    token_endpoint_path = "/instance/service-accounts/default/token"

    resp =
      resp ||
        %{
          "access_token" => "GCP_ACCESS_TOKEN",
          "expires_in" => 3595,
          "token_type" => "Bearer"
        }

    test_pid = self()

    Bypass.stub(bypass, "GET", token_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, JSON.encode!(resp))
    end)

    override_endpoint_url(:metadata_endpoint_url, "http://localhost:#{bypass.port}/")

    bypass
  end

  def mock_sign_blob_endpoint(bypass, service_account_email, resp \\ nil) do
    token_endpoint_path = "service_accounts/#{service_account_email}:signBlob"

    test_pid = self()

    Bypass.expect(bypass, "POST", token_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      {:ok, binary, conn} = Plug.Conn.read_body(conn)
      %{"payload" => payload} = JSON.decode!(binary)

      resp =
        resp ||
          %{
            "keyId" => Ecto.UUID.generate(),
            "signedBlob" => Portal.Crypto.hash(:md5, service_account_email <> payload)
          }

      Plug.Conn.send_resp(conn, 200, JSON.encode!(resp))
    end)

    override_endpoint_url(
      :sign_endpoint_url,
      "http://localhost:#{bypass.port}/service_accounts/"
    )

    bypass
  end

  def mock_instances_list_endpoint(bypass, resp \\ nil) do
    aggregated_instances_endpoint_path =
      "compute/v1/projects/firezone-staging/aggregated/instances"

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

    test_pid = self()

    Bypass.expect(bypass, "GET", aggregated_instances_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:bypass_request, conn})
      Plug.Conn.send_resp(conn, 200, JSON.encode!(resp))
    end)

    override_endpoint_url(
      :aggregated_list_endpoint_url,
      "http://localhost:#{bypass.port}/#{aggregated_instances_endpoint_path}"
    )

    bypass
  end

  def mock_metrics_submit_endpoint(bypass) do
    metrics_endpoint_path = "v3/projects/firezone-staging/timeSeries"

    test_pid = self()

    Bypass.expect(bypass, "POST", metrics_endpoint_path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, binary, conn} = Plug.Conn.read_body(conn)
      body = JSON.decode!(binary)
      send(test_pid, {:bypass_request, conn, body})
      Plug.Conn.send_resp(conn, 200, JSON.encode!(%{}))
    end)

    override_endpoint_url(
      :cloud_metrics_endpoint_url,
      "http://localhost:#{bypass.port}/#{metrics_endpoint_path}"
    )

    bypass
  end
end
