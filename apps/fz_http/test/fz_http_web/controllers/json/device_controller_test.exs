defmodule FzHttpWeb.JSON.DeviceControllerTest do
  use FzHttpWeb.ConnCase, async: true, api: true

  describe "show device" do
    setup :create_device

    test "shows device", %{api_conn: conn, device: %{id: id}} do
      conn = get(conn, ~p"/v0/devices/#{id}")
      assert %{"id" => ^id} = json_response(conn, 200)["data"]
    end
  end

  describe "create device" do
    @params %{
      "name" => "create-name",
      "description" => "create-description",
      "public_key" => "pubkey",
      "preshared_key" => "psk",
      "use_site_allowed_ips" => false,
      "use_site_dns" => false,
      "use_site_endpoint" => false,
      "use_site_mtu" => false,
      "use_site_persistent_keepalive" => false,
      "endpoint" => "9.9.9.9",
      "mtu" => 999,
      "persistent_keepalive" => 9,
      "allowed_ips" => "0.0.0.0/0, ::/0, 1.1.1.1",
      "dns" => "9.9.9.8",
      "ipv4" => "100.64.0.2",
      "ipv6" => "fd00::2"
    }

    @tag params: @params
    test "creates device", %{api_conn: conn, unprivileged_user: %{id: id}, params: params} do
      conn = post(conn, ~p"/v0/devices", device: Map.merge(params, %{"user_id" => id}))
      assert @params = json_response(conn, 201)["data"]
    end
  end

  describe "update device" do
    setup :create_device

    @tag params: %{
           "name" => "json-update-device"
         }
    test "updates device", %{api_conn: conn, params: params, device: %{id: id}} do
      conn = put(conn, ~p"/v0/devices/#{id}", device: params)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v0/devices/#{id}")

      assert %{
               "name" => "json-update-device"
             } = json_response(conn, 200)["data"]
    end
  end

  describe "list devices" do
    setup :create_devices

    test "lists devices", %{api_conn: conn, devices: devices} do
      conn = get(conn, ~p"/v0/devices")
      assert length(json_response(conn, 200)["data"]) == length(devices)
    end
  end

  describe "delete device" do
    setup :create_device

    test "deletes device", %{api_conn: conn, device: device} do
      conn = delete(conn, ~p"/v0/devices/#{device}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/v0/devices/#{device}")
      end
    end
  end
end
