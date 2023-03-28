defmodule FzHttpWeb.JSON.DeviceControllerTest do
  use FzHttpWeb.ApiCase, async: true
  alias FzHttp.{DevicesFixtures, UsersFixtures}

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
    "allowed_ips" => ["0.0.0.0/0", "::/0", "1.1.1.1"],
    "dns" => ["9.9.9.8"],
    "ipv4" => "100.64.0.2",
    "ipv6" => "fd00::2"
  }

  describe "GET /v0/devices/:id" do
    test "shows device" do
      id = DevicesFixtures.create_device().id

      conn =
        get(authed_conn(), ~p"/v0/devices/#{id}")
        |> doc()

      assert %{"id" => ^id} = json_response(conn, 200)["data"]
    end

    test "renders 404 for device not found" do
      conn = get(authed_conn(), ~p"/v0/devices/003da73d-2dd9-4492-8136-3282843545e8")

      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "renders 401 for missing authorization header" do
      device = DevicesFixtures.create_device()
      conn = get(unauthed_conn(), ~p"/v0/devices/#{device}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "POST /v0/devices" do
    test "creates device for unprivileged user" do
      unprivileged_user = UsersFixtures.create_user_with_role(:unprivileged)

      conn =
        post(authed_conn(), ~p"/v0/devices",
          device: Map.merge(@params, %{"user_id" => unprivileged_user.id})
        )
        |> doc()

      assert @params = json_response(conn, 201)["data"]
    end

    test "creates device for self" do
      conn = authed_conn()
      {:user, user} = conn.private.guardian_default_resource.actor
      conn = post(conn, ~p"/v0/devices", device: Map.merge(@params, %{"user_id" => user.id}))
      assert @params = json_response(conn, 201)["data"]
    end

    test "creates device for other admin" do
      admin_user = UsersFixtures.create_user_with_role(:admin)

      conn =
        post(authed_conn(), ~p"/v0/devices",
          device: Map.merge(@params, %{"user_id" => admin_user.id})
        )

      assert @params = json_response(conn, 201)["data"]
    end

    test "renders 401 for missing authorization header" do
      conn = post(unauthed_conn(), ~p"/v0/devices", device: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "PUT /v0/devices/:id" do
    test "updates device" do
      device = DevicesFixtures.create_device()

      update_attrs = %{
        "name" => "update-name",
        "description" => "update-description"
      }

      conn =
        put(authed_conn(), ~p"/v0/devices/#{device}", device: update_attrs)
        |> doc()

      assert device = json_response(conn, 200)["data"]
      assert device["name"] == update_attrs["name"]
      assert device["description"] == update_attrs["description"]
    end

    test "renders 404 for device not found" do
      conn = put(authed_conn(), ~p"/v0/devices/003da73d-2dd9-4492-8136-3282843545e8", device: %{})

      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "renders 401 for missing authorization header" do
      conn = put(unauthed_conn(), ~p"/v0/devices/#{DevicesFixtures.create_device()}", device: %{})
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "GET /v0/devices" do
    test "lists all devices" do
      devices = for _i <- 1..5, do: DevicesFixtures.create_device()

      conn =
        get(authed_conn(), ~p"/v0/devices")
        |> doc()

      assert json_response(conn, 200)["data"]
             |> Enum.map(& &1["id"])
             |> MapSet.new() ==
               devices
               |> Enum.map(& &1.id)
               |> MapSet.new()
    end

    test "renders 401 for missing authorization header" do
      conn = get(unauthed_conn(), ~p"/v0/devices")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end

  describe "DELETE /v0/devices/:id" do
    test "deletes device" do
      device = DevicesFixtures.create_device()

      conn =
        delete(authed_conn(), ~p"/v0/devices/#{device}")
        |> doc()

      assert response(conn, 204)

      conn = get(conn, ~p"/v0/devices/#{device}")

      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "renders 404 for device not found" do
      conn = delete(authed_conn(), ~p"/v0/devices/003da73d-2dd9-4492-8136-3282843545e8")

      assert json_response(conn, 404) == %{"error" => "not_found"}
    end

    test "renders 401 for missing authorization header" do
      conn = delete(unauthed_conn(), ~p"/v0/devices/#{DevicesFixtures.create_device()}")
      assert json_response(conn, 401)["errors"] == %{"auth" => "unauthenticated"}
    end
  end
end
