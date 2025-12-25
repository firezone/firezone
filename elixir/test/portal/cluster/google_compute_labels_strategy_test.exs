defmodule Portal.Cluster.GoogleComputeLabelsStrategyTest do
  use ExUnit.Case, async: true
  import Portal.Cluster.GoogleComputeLabelsStrategy
  alias Portal.Mocks.GoogleCloudPlatform

  describe "fetch_nodes/1" do
    test "returns list of nodes in all regions when access token is not set" do
      bypass = Bypass.open()
      GoogleCloudPlatform.mock_instance_metadata_token_endpoint(bypass)
      GoogleCloudPlatform.mock_instances_list_endpoint(bypass)

      state = %{
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          cluster_version: "1"
        ]
      }

      assert {:ok, nodes, _state} = fetch_nodes(state)

      assert nodes == [
               :"api@api-q3j6.us-east1-d.c.firezone-staging.internal"
             ]
    end
  end
end
