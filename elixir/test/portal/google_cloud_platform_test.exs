defmodule Portal.GoogleCloudPlatformTest do
  use ExUnit.Case, async: true
  import Portal.GoogleCloudPlatform
  alias Portal.Mocks.GoogleCloudPlatform

  describe "fetch_and_cache_access_token/0" do
    test "returns instance default account service token" do
      GoogleCloudPlatform.stub(GoogleCloudPlatform.mock_instance_metadata_token_endpoint())

      assert {:ok, token} = fetch_and_cache_access_token()
      assert token
    end
  end

  describe "fetch_access_token/0" do
    test "returns instance default account service token" do
      GoogleCloudPlatform.stub(GoogleCloudPlatform.mock_instance_metadata_token_endpoint())

      assert {:ok, token, token_expires_at} = fetch_access_token()
      assert token
      assert %DateTime{} = token_expires_at
    end

    test "returns error on failure" do
      GoogleCloudPlatform.stub([
        {"GET", ~r|/instance/service-accounts/default/token|, 500, %{"error" => "server error"}}
      ])

      assert {:error, {500, _body}} = fetch_access_token()
    end
  end

  describe "list_google_cloud_instances_by_labels/2" do
    test "returns list of nodes in all regions" do
      expectations =
        GoogleCloudPlatform.mock_instance_metadata_token_endpoint() ++
          GoogleCloudPlatform.mock_instances_list_endpoint()

      GoogleCloudPlatform.stub(expectations)

      assert {:ok, nodes} =
               list_google_cloud_instances_by_labels(
                 "firezone-staging",
                 %{
                   "cluster_name" => "firezone",
                   "version" => "0-0-1"
                 }
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

    test "returns error when compute endpoint returns error" do
      expectations =
        GoogleCloudPlatform.mock_instance_metadata_token_endpoint() ++
          [
            {"GET", ~r|/compute/v1/projects/.*/aggregated/instances|, 500,
             %{"error" => "server error"}}
          ]

      GoogleCloudPlatform.stub(expectations)

      assert {:error, {500, _body}} =
               list_google_cloud_instances_by_labels("firezone-staging", %{
                 "cluster_name" => "firezone"
               })
    end

    test "returns error when token endpoint returns error" do
      GoogleCloudPlatform.stub([
        {"GET", ~r|/instance/service-accounts/default/token|, 500, %{"error" => "server error"}}
      ])

      assert {:error, {500, _body}} =
               list_google_cloud_instances_by_labels("firezone-staging", %{
                 "cluster_name" => "firezone"
               })
    end
  end

  describe "send_metrics/2" do
    test "sends metrics successfully" do
      expectations =
        GoogleCloudPlatform.mock_instance_metadata_token_endpoint() ++
          GoogleCloudPlatform.mock_metrics_submit_endpoint()

      GoogleCloudPlatform.stub(expectations)

      time_series = [
        %{
          "metric" => %{
            "type" => "custom.googleapis.com/my_metric",
            "labels" => %{
              "my_label" => "my_value"
            }
          },
          "resource" => %{
            "type" => "gce_instance",
            "labels" => %{
              "project_id" => "firezone-staging",
              "instance_id" => "1234567890123456789",
              "zone" => "us-central1-f"
            }
          },
          "points" => [
            %{
              "interval" => %{
                "endTime" => "2024-04-05T10:00:00-04:00"
              },
              "value" => %{
                "doubleValue" => 123.45
              }
            }
          ]
        }
      ]

      assert send_metrics("firezone-staging", time_series) == :ok
    end

    test "returns error when metrics endpoint returns error" do
      expectations =
        GoogleCloudPlatform.mock_instance_metadata_token_endpoint() ++
          [{"POST", ~r|/v3/projects/.*/timeSeries|, 500, %{"error" => "server error"}}]

      GoogleCloudPlatform.stub(expectations)

      assert {:error, {500, _body}} =
               send_metrics("firezone-staging", %{
                 "cluster_name" => "firezone"
               })
    end

    test "returns error when token endpoint returns error" do
      GoogleCloudPlatform.stub([
        {"GET", ~r|/instance/service-accounts/default/token|, 500, %{"error" => "server error"}}
      ])

      assert {:error, {500, _body}} =
               send_metrics("firezone-staging", %{
                 "cluster_name" => "firezone"
               })
    end
  end
end
