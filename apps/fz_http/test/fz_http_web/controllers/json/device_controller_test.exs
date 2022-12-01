defmodule FzHttpWeb.JSON.DeviceControllerTest do
  use FzHttpWeb.APICase

  describe "show device" do
    setup :create_device

    test "shows device", %{conn: conn, device: %{id: id}} do
      conn = get(conn, ~p"/v1/devices/#{id}")
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
      "ipv4" => "10.3.2.100",
      "ipv6" => "fd00::3:2:e"
    }

    @tag params: @params
    test "creates device", %{conn: conn, unprivileged_user: user, params: params} do
      conn = post(conn, ~p"/v1/devices", device: Map.merge(params, %{"user_id" => user.id}))
      assert @params = json_response(conn, 201)["data"]
    end
  end

  describe "update device" do
    setup :create_device

    @tag params: %{
           "name" => "json-update-device"
         }
    test "updates device", %{conn: conn, params: params, device: device} do
      conn = put(conn, ~p"/v1/devices/#{device}", device: params)
      id = device.id
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v1/devices/#{device}")

      assert %{
               "name" => "json-update-device"
             } = json_response(conn, 200)["data"]
    end
  end

  describe "list devices" do
    setup :create_devices

    test "lists devices", %{conn: conn, devices: devices} do
      conn = get(conn, ~p"/v1/devices")
      assert length(json_response(conn, 200)["data"]) == 5
    end
  end

  describe "delete device" do
    setup :create_device

    test "deletes device", %{conn: conn, device: device} do
      conn = delete(conn, ~p"/v1/devices/#{device}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/v1/devices/#{device}")
      end
    end
  end
end
