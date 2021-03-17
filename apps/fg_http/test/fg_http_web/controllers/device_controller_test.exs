defmodule FgHttpWeb.DeviceControllerUnauthedTest do
  use FgHttpWeb.ConnCase, async: true

  describe "index" do
    test "redirects to new session", %{unauthed_conn: conn} do
      test_conn = get(conn, Routes.device_path(conn, :index))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end

  describe "show" do
    setup [:create_device]

    test "redirects to new session", %{unauthed_conn: conn, device: device} do
      test_conn = get(conn, Routes.device_path(conn, :show, device))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end

  describe "create" do
    test "redirects to new session", %{unauthed_conn: conn} do
      test_conn = post(conn, Routes.device_path(conn, :create))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end

  describe "delete" do
    setup [:create_device]

    test "redirects to new session", %{unauthed_conn: conn, device: device} do
      test_conn = delete(conn, Routes.device_path(conn, :delete, device))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end
end

defmodule FgHttpWeb.DeviceControllerAuthedTest do
  use FgHttpWeb.ConnCase, async: true

  describe "show" do
    setup [:create_device]

    test "shows the device", %{authed_conn: conn, device: device} do
      test_conn = get(conn, Routes.device_path(conn, :show, device))
      assert html_response(test_conn, 200) =~ device.name
    end
  end

  describe "index" do
    setup [:create_device]

    test "lists all devices", %{authed_conn: conn, device: device} do
      test_conn = get(conn, Routes.device_path(conn, :index))
      assert html_response(test_conn, 200) =~ "<h3 class=\"title\">Devices</h3>"
      assert html_response(test_conn, 200) =~ device.name
    end
  end

  describe "create" do
    test "redirects when data is valid", %{authed_conn: conn} do
      test_conn = post(conn, Routes.device_path(conn, :create))
      devices = FgHttp.Devices.list_devices()
      device = devices |> List.first()
      assert redirected_to(test_conn) == Routes.device_path(test_conn, :show, device)
    end
  end

  describe "delete" do
    setup [:create_device]

    test "deletes chosen device", %{authed_conn: conn, device: device} do
      test_conn = delete(conn, Routes.device_path(conn, :delete, device))
      assert redirected_to(test_conn) == Routes.device_path(conn, :index)

      assert_error_sent 404, fn ->
        get(test_conn, Routes.device_path(test_conn, :show, device))
      end
    end
  end
end
