defmodule Domain.Cluster.GoogleComputeLabelsStrategyTest do
  use ExUnit.Case, async: true
  import Domain.Cluster.GoogleComputeLabelsStrategy
  alias Domain.Mocks.GoogleCloudPlatform

  describe "fetch_nodes/1" do
    test "returns list of nodes in all regions when access token is not set" do
      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_instances_list_endpoint(bypass)

      state = %{
        topology: :test,
        connect: :test,
        list_nodes: :test,
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          cluster_version: "1",
          api_node_count: 1,
          domain_node_count: 1,
          web_node_count: 1,
          health_check_supported: true
        ]
      }

      assert {:ok, nodes, _state} = fetch_nodes(state)

      assert nodes == [
               :"api@api-q3j6.us-east1-d.c.firezone-staging.internal",
               :"domain@domain-q3j6.us-east1-d.c.firezone-staging.internal",
               :"web@web-q3j6.us-east1-d.c.firezone-staging.internal"
             ]
    end
  end

  describe "load/1" do
    setup do
      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_instances_list_endpoint(bypass)

      Application.put_env(:domain, :cluster_strategy_reply, :ok)

      :ok
    end

    test "healthy?/0 is true when all nodes connected" do
      state = %{
        topology: :test,
        connect: :test,
        list_nodes: :test,
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          cluster_version: "1",
          api_node_count: 1,
          domain_node_count: 1,
          web_node_count: 1,
          health_check_supported: true
        ]
      }

      assert %{healthy?: true} = load(state)
    end

    test "healthy?/0 is false when not all expected nodes are connected" do
      state = %{
        topology: :test,
        connect: :test,
        list_nodes: :test,
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          cluster_version: "1",
          api_node_count: 2,
          domain_node_count: 1,
          web_node_count: 1,
          health_check_supported: true
        ]
      }

      assert %{healthy?: false} = load(state)
    end

    test "healthy?/0 is false if error connecting nodes" do
      Application.put_env(:domain, :cluster_strategy_reply, {:error, "test"})

      state = %{
        topology: :test,
        connect: :test,
        list_nodes: :test,
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          cluster_version: "1",
          api_node_count: 1,
          domain_node_count: 1,
          web_node_count: 1,
          health_check_supported: true
        ]
      }

      assert %{healthy?: false} = load(state)
    end
  end
end
