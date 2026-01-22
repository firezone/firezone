defmodule Portal.Plugs.ValidateAzureFrontDoorTest do
  use Portal.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias Portal.Plugs.ValidateAzureFrontDoor

  @expected_front_door_id "12345678-1234-1234-1234-123456789abc"

  describe "call/2 when azure_front_door_id is not configured" do
    setup do
      Portal.Config.put_env_override(:portal, :azure_front_door_id, nil)
      :ok
    end

    test "passes through requests without X-Azure-FDID header" do
      conn =
        :get
        |> conn("/")
        |> ValidateAzureFrontDoor.call([])

      refute conn.halted
    end

    test "passes through requests with any X-Azure-FDID header" do
      conn =
        :get
        |> conn("/")
        |> put_req_header("x-azure-fdid", "any-value")
        |> ValidateAzureFrontDoor.call([])

      refute conn.halted
    end
  end

  describe "call/2 when azure_front_door_id is configured" do
    setup do
      Portal.Config.put_env_override(:portal, :azure_front_door_id, @expected_front_door_id)
      :ok
    end

    test "passes through requests with matching X-Azure-FDID header" do
      conn =
        :get
        |> conn("/")
        |> put_req_header("x-azure-fdid", @expected_front_door_id)
        |> ValidateAzureFrontDoor.call([])

      refute conn.halted
    end

    test "rejects requests without X-Azure-FDID header" do
      conn =
        :get
        |> conn("/")
        |> ValidateAzureFrontDoor.call([])

      assert conn.halted
      assert conn.status == 502
      assert conn.resp_body == "Bad Gateway"
    end

    test "rejects requests with invalid X-Azure-FDID header" do
      conn =
        :get
        |> conn("/")
        |> put_req_header("x-azure-fdid", "wrong-id")
        |> ValidateAzureFrontDoor.call([])

      assert conn.halted
      assert conn.status == 502
      assert conn.resp_body == "Bad Gateway"
    end

    test "rejects requests with multiple X-Azure-FDID headers" do
      # Manually add duplicate headers since put_req_header replaces
      base_conn = conn(:get, "/")

      conn =
        %{
          base_conn
          | req_headers: [
              {"x-azure-fdid", @expected_front_door_id},
              {"x-azure-fdid", "another-id"} | base_conn.req_headers
            ]
        }
        |> ValidateAzureFrontDoor.call([])

      assert conn.halted
      assert conn.status == 502
      assert conn.resp_body == "Bad Gateway"
    end

    test "GUID matching is case-insensitive" do
      # GUIDs are case-insensitive, so uppercase should match lowercase config
      conn =
        :get
        |> conn("/")
        |> put_req_header("x-azure-fdid", String.upcase(@expected_front_door_id))
        |> ValidateAzureFrontDoor.call([])

      refute conn.halted
    end
  end
end
