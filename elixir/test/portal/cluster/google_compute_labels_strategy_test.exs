defmodule Portal.Cluster.GoogleComputeLabelsStrategyTest do
  use ExUnit.Case, async: true
  import Portal.Cluster.GoogleComputeLabelsStrategy
  alias Portal.Mocks.GoogleCloudPlatform

  setup do
    # Start an unregistered Instance GenServer for this test (not linked to avoid crashes)
    {:ok, instance_pid} = GenServer.start(Portal.GoogleCloudPlatform.Instance, nil)

    # Store the server PID in the process dictionary so fetch_access_token uses it
    Process.put(:gcp_instance_server, instance_pid)

    # Register a default stub first
    Req.Test.stub(Portal.GoogleCloudPlatform, fn conn ->
      Plug.Conn.send_resp(conn, 500, "no stub configured")
    end)

    # Allow the Instance GenServer to access the stub
    Req.Test.allow(Portal.GoogleCloudPlatform, self(), instance_pid)

    on_exit(fn ->
      if Process.alive?(instance_pid), do: GenServer.stop(instance_pid)
    end)

    :ok
  end

  describe "fetch_nodes/1" do
    test "returns list of nodes in all regions when access token is not set" do
      expectations =
        GoogleCloudPlatform.mock_instance_metadata_token_endpoint() ++
          GoogleCloudPlatform.mock_instances_list_endpoint()

      GoogleCloudPlatform.stub(expectations)

      state = %{
        config: [
          project_id: "firezone-staging",
          cluster_name: "firezone",
          cluster_version: "1",
          release_name: "portal"
        ]
      }

      assert {:ok, nodes, _state} = fetch_nodes(state)

      assert nodes == [
               :"portal@10.128.0.43"
             ]
    end
  end
end
