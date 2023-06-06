defmodule Domain.Cluster.GoogleComputeLabelsStrategyTest do
  use ExUnit.Case, async: true
  import Domain.Cluster.GoogleComputeLabelsStrategy
  alias Domain.Cluster.GoogleComputeLabelsStrategy.Meta
  alias Cluster.Strategy.State
  alias Domain.Mocks.GoogleCloudPlatform

  describe "refresh_access_token/1" do
    test "returns access token" do
      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)

      state = %State{meta: %Meta{}}
      assert {:ok, state} = refresh_access_token(state)
      assert state.meta.access_token == "GCP_ACCESS_TOKEN"

      expected_access_token_expires_at = DateTime.add(DateTime.utc_now(), 3595, :second)

      assert DateTime.diff(state.meta.access_token_expires_at, expected_access_token_expires_at) in -2..2

      assert_receive {:bypass_request, conn}
      assert {"metadata-flavor", "Google"} in conn.req_headers
    end

    test "returns error when endpoint is not available" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      GoogleCloudPlatform.override_endpoint_url(
        :token_endpoint_url,
        "http://localhost:#{bypass.port}/"
      )

      state = %State{meta: %Meta{}}

      assert refresh_access_token(state) ==
               {:error, %Mint.TransportError{reason: :econnrefused}}
    end
  end

  describe "fetch_nodes/1" do
    test "returns list of nodes in all regions when access token is not set" do
      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_instances_list_endpoint(bypass)

      state = %State{
        meta: %Meta{},
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone"
        ]
      }

      assert {:ok, nodes, state} = fetch_nodes(state)

      assert nodes == [
               :"api@api-q3j6.us-east1-d.c.firezone-staging.internal"
             ]

      assert state.meta.access_token
      assert state.meta.access_token_expires_at
    end

    test "retruns list of nodes when token is not expired" do
      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instances_list_endpoint(bypass)

      state = %State{
        meta: %Meta{
          access_token: "ACCESS_TOKEN",
          access_token_expires_at: DateTime.utc_now() |> DateTime.add(5, :second)
        },
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          backoff_interval: 1
        ]
      }

      assert {:ok, nodes, ^state} = fetch_nodes(state)

      assert nodes == [
               :"api@api-q3j6.us-east1-d.c.firezone-staging.internal"
             ]

      assert_receive {:bypass_request, conn}
      assert {"authorization", "Bearer ACCESS_TOKEN"} in conn.req_headers
    end

    test "returns error when compute endpoint is down" do
      bypass = Bypass.open()
      Bypass.down(bypass)

      GoogleCloudPlatform.override_endpoint_url(
        :aggregated_list_endpoint_url,
        "http://localhost:#{bypass.port}/"
      )

      state = %State{
        meta: %Meta{
          access_token: "ACCESS_TOKEN",
          access_token_expires_at: DateTime.utc_now() |> DateTime.add(5, :second)
        },
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          backoff_interval: 1
        ]
      }

      assert fetch_nodes(state) == {:error, %Mint.TransportError{reason: :econnrefused}}

      GoogleCloudPlatform.override_endpoint_url(
        :token_endpoint_url,
        "http://localhost:#{bypass.port}/"
      )

      state = %State{
        meta: %Meta{},
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          backoff_interval: 1
        ]
      }

      assert fetch_nodes(state) == {:error, %Mint.TransportError{reason: :econnrefused}}
    end

    test "refreshes the access token if it expired" do
      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_instances_list_endpoint(bypass)

      state = %State{
        meta: %Meta{
          access_token: "ACCESS_TOKEN",
          access_token_expires_at: DateTime.utc_now() |> DateTime.add(-5, :second)
        },
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          backoff_interval: 1
        ]
      }

      assert {:ok, _nodes, updated_state} = fetch_nodes(state)

      assert updated_state.meta.access_token != state.meta.access_token
      assert updated_state.meta.access_token_expires_at != state.meta.access_token_expires_at
    end

    test "refreshes the access token if it became invalid even through did not expire" do
      resp = %{
        "error" => %{
          "code" => 401,
          "status" => "UNAUTHENTICATED"
        }
      }

      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_instances_list_endpoint(bypass, resp)

      state = %State{
        meta: %Meta{
          access_token: "ACCESS_TOKEN",
          access_token_expires_at: DateTime.utc_now() |> DateTime.add(5, :second)
        },
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          backoff_interval: 1
        ]
      }

      assert {:error, _reason} = fetch_nodes(state)
    end
  end
end
