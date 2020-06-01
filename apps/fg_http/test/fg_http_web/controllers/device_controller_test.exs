defmodule FgHttpWeb.DeviceControllerTest do
  use FgHttpWeb.ConnCase, async: true

  alias FgHttp.Fixtures

  @create_attrs %{public_key: "foobar"}
  @update_attrs %{name: "some updated name"}
  @invalid_attrs %{public_key: nil}

  describe "index" do
    test "lists all devices", %{authed_conn: conn} do
      conn = get(conn, Routes.device_path(conn, :index))
      assert html_response(conn, 200) =~ "Listing Devices"
    end
  end

  describe "new device" do
    test "renders form", %{authed_conn: conn} do
      conn = get(conn, Routes.device_path(conn, :new))
      assert html_response(conn, 200) =~ "New Device"
    end
  end

  describe "create device" do
    test "redirects when data is valid", %{authed_conn: conn} do
      conn = post(conn, Routes.device_path(conn, :create), device: @create_attrs)
      assert html_response(conn, 302) =~ "redirected"
    end

    test "renders errors when data is invalid", %{authed_conn: conn} do
      conn = post(conn, Routes.device_path(conn, :create), device: @invalid_attrs)
      assert html_response(conn, 200) =~ "public_key: can&#39;t be blank"
    end
  end

  describe "edit device" do
    setup [:create_device]

    test "renders form for editing chosen device", %{authed_conn: conn, device: device} do
      conn = get(conn, Routes.device_path(conn, :edit, device))
      assert html_response(conn, 200) =~ "Edit Device"
    end
  end

  describe "update device" do
    setup [:create_device]

    test "redirects when data is valid", %{authed_conn: conn, device: device} do
      test_conn = put(conn, Routes.device_path(conn, :update, device), device: @update_attrs)
      assert redirected_to(test_conn) == Routes.device_path(conn, :show, device)

      test_conn = get(conn, Routes.device_path(conn, :show, device))
      assert html_response(test_conn, 200) =~ "some updated name"
    end

    test "renders errors when data is invalid", %{authed_conn: conn, device: device} do
      conn = put(conn, Routes.device_path(conn, :update, device), device: @invalid_attrs)
      assert html_response(conn, 200) =~ "Edit Device"
    end
  end

  describe "delete device" do
    setup [:create_device]

    test "deletes chosen device", %{authed_conn: conn, device: device} do
      test_conn = delete(conn, Routes.device_path(conn, :delete, device))
      assert redirected_to(test_conn) == Routes.device_path(conn, :index)

      assert_error_sent 404, fn ->
        get(conn, Routes.device_path(conn, :show, device))
      end
    end
  end

  defp create_device(_) do
    device = Fixtures.device()
    {:ok, device: device}
  end
end
