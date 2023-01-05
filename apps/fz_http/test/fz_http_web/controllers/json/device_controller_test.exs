defmodule FzHttpWeb.JSON.DeviceControllerTest do
  use FzHttpWeb.ApiCase, async: true

  @params %{
    "name" => "create-name",
    "description" => "create-description",
    "public_key" => "CHqFuS+iL3FTog5F4Ceumqlk0CU4Cl/dyUP/9F9NDnI=",
    "preshared_key" => "CHqFuS+iL3FTog5F4Ceumqlk0CU4Cl/dyUP/9F9NDnI=",
    "use_default_allowed_ips" => false,
    "use_default_dns" => false,
    "use_default_endpoint" => false,
    "use_default_mtu" => false,
    "use_default_persistent_keepalive" => false,
    "endpoint" => "9.9.9.9",
    "mtu" => 999,
    "persistent_keepalive" => 9,
    "allowed_ips" => "0.0.0.0/0, ::/0, 1.1.1.1",
    "dns" => "9.9.9.8",
    "ipv4" => "100.64.0.2",
    "ipv6" => "fd00::2"
  }

  describe "GET /v0/devices/:id" do
    setup :create_device

    test "shows device", %{authed_conn: conn, device: %{id: id}} do
      conn = get(conn, ~p"/v0/devices/#{id}")
      assert %{"id" => ^id} = json_response(conn, 200)["data"]
    end

    test "renders 401 for missing authorization header", %{unauthed_conn: conn, device: device} do
      conn = get(conn, ~p"/v0/devices/#{device}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end

    test "renders 404 for device not found", %{authed_conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/v0/devices/003da73d-2dd9-4492-8136-3282843545e8")
      end
    end
  end

  describe "POST /v0/devices" do
    import FzHttp.UsersFixtures

    @tag params: @params
    test "creates device for unprivileged user", %{authed_conn: conn, params: params} do
      unprivileged_user = user(%{role: :unprivileged})

      conn =
        post(conn, ~p"/v0/devices",
          device: Map.merge(params, %{"user_id" => unprivileged_user.id})
        )

      assert @params = json_response(conn, 201)["data"]
    end

    @tag params: @params
    test "creates device for self", %{authed_conn: conn, params: params} do
      conn =
        post(conn, ~p"/v0/devices",
          device: Map.merge(params, %{"user_id" => conn.private.guardian_default_resource.id})
        )

      assert @params = json_response(conn, 201)["data"]
    end

    @tag params: @params
    test "creates device for other admin", %{authed_conn: conn, params: params} do
      admin_user = user(%{role: :admin})
      conn = post(conn, ~p"/v0/devices", device: Map.merge(params, %{"user_id" => admin_user.id}))
      assert @params = json_response(conn, 201)["data"]
    end

    test "renders 401 for missing authorization header", %{unauthed_conn: conn} do
      conn = post(conn, ~p"/v0/devices", device: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "PUT /v0/devices/:id" do
    setup :create_device

    @tag params: @params
    test "updates device", %{authed_conn: conn, params: params, device: %{id: id}} do
      conn = put(conn, ~p"/v0/devices/#{id}", device: params)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/v0/devices/#{id}")
      assert @params = json_response(conn, 200)["data"]
    end

    test "renders 401 for missing authorization header", %{unauthed_conn: conn, device: device} do
      conn = put(conn, ~p"/v0/devices/#{device}", device: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end

    test "renders 404 for device not found", %{authed_conn: conn} do
      assert_error_sent 404, fn ->
        put(conn, ~p"/v0/devices/003da73d-2dd9-4492-8136-3282843545e8", device: %{})
      end
    end
  end

  describe "GET /v0/devices" do
    setup :create_devices

    test "lists all devices", %{authed_conn: conn, devices: devices} do
      conn = get(conn, ~p"/v0/devices")

      assert json_response(conn, 200)["data"]
             |> Enum.map(& &1["id"])
             |> MapSet.new() ==
               devices
               |> Enum.map(& &1.id)
               |> MapSet.new()
    end

    test "renders 401 for missing authorization header", %{unauthed_conn: conn} do
      conn = get(conn, ~p"/v0/devices")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "DELETE /v0/devices/:id" do
    setup :create_device

    test "deletes device", %{authed_conn: conn, device: device} do
      conn = delete(conn, ~p"/v0/devices/#{device}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/v0/devices/#{device}")
      end
    end

    test "renders 401 for missing authorization header", %{unauthed_conn: conn, device: device} do
      conn = delete(conn, ~p"/v0/devices/#{device}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end

    test "renders 404 for device not found", %{authed_conn: conn} do
      assert_error_sent 404, fn ->
        delete(conn, ~p"/v0/devices/003da73d-2dd9-4492-8136-3282843545e8")
      end
    end
  end
end
