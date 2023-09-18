defmodule Domain.GoogleCloudPlatformTest do
  use ExUnit.Case, async: true
  import Domain.GoogleCloudPlatform
  alias Domain.Mocks.GoogleCloudPlatform

  setup do
    bypass = Bypass.open()
    %{bypass: bypass}
  end

  describe "fetch_and_cache_access_token/0" do
    test "returns instance default account service token", %{bypass: bypass} do
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)

      assert {:ok, token} = fetch_and_cache_access_token()
      assert token
    end

    test "caches the access token", %{bypass: bypass} do
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      assert {:ok, _token} = fetch_and_cache_access_token()

      Bypass.down(bypass)
      assert {:ok, _token} = fetch_and_cache_access_token()
    end
  end

  describe "fetch_access_token/0" do
    test "returns instance default account service token", %{bypass: bypass} do
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)

      assert {:ok, token, token_expires_at} = fetch_access_token()
      assert token
      assert %DateTime{} = token_expires_at
    end

    test "returns error on failure", %{bypass: bypass} do
      Bypass.down(bypass)
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)

      assert fetch_access_token() ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end
  end

  describe "list_google_cloud_instances_by_label/3" do
    test "returns list of nodes in all regions when access token is not set", %{bypass: bypass} do
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_instances_list_endpoint(bypass)

      assert {:ok, nodes} =
               list_google_cloud_instances_by_label(
                 "firezone-staging",
                 "cluster_name",
                 "firezone"
               )

      assert length(nodes) == 1

      assert [
               %{
                 "name" => "api-q3j6",
                 "zone" =>
                   "https://www.googleapis.com/compute/v1/projects/firezone-staging/zones/us-east1-d",
                 "labels" => %{
                   "application" => "api",
                   "cluster_name" => "firezone",
                   "container-vm" => "cos-105-17412-101-13",
                   "managed_by" => "terraform",
                   "version" => "0-0-1"
                 }
               }
             ] = nodes
    end

    test "returns error when compute endpoint is down", %{bypass: bypass} do
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)

      Bypass.down(bypass)

      GoogleCloudPlatform.override_endpoint_url(
        :aggregated_list_endpoint_url,
        "http://localhost:#{bypass.port}/"
      )

      assert list_google_cloud_instances_by_label("firezone-staging", "cluster_name", "firezone") ==
               {:error, %Mint.TransportError{reason: :econnrefused}}

      GoogleCloudPlatform.override_endpoint_url(
        :token_endpoint_url,
        "http://localhost:#{bypass.port}/"
      )

      assert list_google_cloud_instances_by_label("firezone-staging", "cluster_name", "firezone") ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end
  end

  describe "sign_url/3" do
    test "returns error when endpoint is not available", %{bypass: bypass} do
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)

      GoogleCloudPlatform.override_endpoint_url(
        :sign_endpoint_url,
        "http://localhost:#{bypass.port}/"
      )

      Bypass.down(bypass)

      assert sign_url("logs", "clients/id/log.json.tar.gz", verb: "PUT") ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    test "returns error when endpoint returns an error", %{bypass: bypass} do
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_sign_blob_endpoint(bypass, "foo", %{"error" => "reason"})

      assert sign_url("logs", "clients/id/log.json.tar.gz", verb: "PUT") ==
               {:error, %{"error" => "reason"}}
    end

    test "returns signed url", %{bypass: bypass} do
      fixed_datetime = ~U[2000-01-01 00:00:00.000000Z]
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_sign_blob_endpoint(bypass, "foo")

      assert {:ok, signed_url} =
               sign_url("logs", "clients/id/log.json.tar.gz",
                 verb: "PUT",
                 valid_from: fixed_datetime
               )

      assert {:ok, signed_uri} = URI.new(signed_url)

      assert signed_uri.scheme == "https"
      assert signed_uri.host == "storage.googleapis.com"
      assert signed_uri.path == "/logs/clients/id/log.json.tar.gz"

      assert URI.decode_query(signed_uri.query) == %{
               "X-Goog-Algorithm" => "GOOG4-RSA-SHA256",
               "X-Goog-Credential" => "foo@iam.example.com/20000101/auto/storage/goog4_request",
               "X-Goog-Date" => "20000101T000000Z",
               "X-Goog-Expires" => "604800",
               "X-Goog-Signature" => "efdd75f1feb87fa75a71ee36e9bf1bd35f777fcdb9e7cd1f",
               "X-Goog-SignedHeaders" => "host"
             }

      assert_receive {:bypass_request,
                      %{request_path: "/service_accounts/foo@iam.example.com:signBlob"} = conn}

      assert {"authorization", "Bearer GCP_ACCESS_TOKEN"} in conn.req_headers
      assert conn.method == "POST"
    end
  end
end
