defmodule FgHttpWeb.DeviceControllerTestHelpers do
  alias FgHttp.Fixtures

  def create_device(_) do
    device = Fixtures.device()
    {:ok, device: device}
  end
end

defmodule FgHttpWeb.DeviceControllerUnauthedTest do
  use FgHttpWeb.ConnCase, async: true
  import FgHttpWeb.DeviceControllerTestHelpers

  @update_attrs %{name: "some updated name"}

  describe "index" do
    test "redirects to new session", %{unauthed_conn: conn} do
      test_conn = get(conn, Routes.device_path(conn, :index))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end

  describe "create device" do
    test "redirects to new session", %{unauthed_conn: conn} do
      test_conn = post(conn, Routes.device_path(conn, :create))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end

  describe "edit device" do
    setup [:create_device]

    test "redirects to new session", %{unauthed_conn: conn, device: device} do
      test_conn = get(conn, Routes.device_path(conn, :edit, device))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end

  describe "update device" do
    setup [:create_device]

    test "redirects to new session", %{unauthed_conn: conn, device: device} do
      test_conn = put(conn, Routes.device_path(conn, :update, device), device: @update_attrs)
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end

  describe "delete device" do
    setup [:create_device]

    test "redirects to new session", %{unauthed_conn: conn, device: device} do
      test_conn = delete(conn, Routes.device_path(conn, :delete, device))
      assert redirected_to(test_conn) == Routes.session_path(test_conn, :new)
    end
  end
end

defmodule FgHttpWeb.DeviceControllerAuthedTest do
  use FgHttpWeb.ConnCase, async: true
  import FgHttpWeb.DeviceControllerTestHelpers

  @update_attrs %{name: "some updated name"}
  @invalid_attrs %{public_key: nil}

  describe "show" do
    setup [:create_device]

    test "shows the device", %{authed_conn: conn, device: device} do
      test_conn = get(conn, Routes.device_path(conn, :show, device))
      assert html_response(test_conn, 200) =~ "Show Device"
    end
  end

  describe "index" do
    test "lists all devices", %{authed_conn: conn} do
      test_conn = get(conn, Routes.device_path(conn, :index))
      assert html_response(test_conn, 200) =~ "Listing Devices"
    end
  end

  describe "create device" do
    test "redirects when data is valid", %{authed_conn: conn} do
      test_conn = post(conn, Routes.device_path(conn, :create))
      devices = FgHttp.Devices.list_devices()
      device = devices |> List.first()
      assert redirected_to(test_conn) == Routes.device_path(test_conn, :show, device)
    end
  end

  describe "edit device" do
    setup [:create_device]

    test "renders form for editing chosen device", %{authed_conn: conn, device: device} do
      test_conn = get(conn, Routes.device_path(conn, :edit, device))
      assert html_response(test_conn, 200) =~ "Edit Device"
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
end
