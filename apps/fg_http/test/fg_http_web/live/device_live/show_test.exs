defmodule FgHttpWeb.DeviceLive.ShowTest do
  use FgHttpWeb.ConnCase, async: true

  describe "authenticated" do
    setup :create_device

    @valid_params %{"device" => %{"name" => "new_name"}}
    @invalid_params %{"device" => %{"name" => ""}}

    test "shows device details", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      {:ok, _view, html} = live(conn, path)
      assert html =~ "<h3 class=\"title\">#{device.name}</h3>"
    end

    test "opens modal", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("a", "Edit")
      |> render_click()

      assert_patched(view, Routes.device_show_path(conn, :edit, device))
    end

    test "allows name changes", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> form("#edit-device")
      |> render_submit(@valid_params)

      flash = assert_redirected(view, Routes.device_show_path(conn, :show, device))
      assert flash["info"] == "Device updated successfully."
    end

    test "prevents empty names", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :edit, device)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#edit-device")
        |> render_submit(@invalid_params)

      assert test_view =~ "can&#39;t be blank"
    end
  end

  describe "delete own device" do
    setup :create_device

    test "successful", %{authed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      {:ok, view, _html} = live(conn, path)

      view
      |> element("button", "Delete device")
      |> render_click()

      flash = assert_redirected(view, Routes.device_index_path(conn, :index))
      assert flash["info"] == "Device deleted successfully."
    end
  end

  describe "delete other device" do
    setup [:create_device, :create_other_user_device]

    test "fails", %{authed_conn: conn, other_device: other_device, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      {:ok, view, _html} = live(conn, path)
      params = %{"device_id" => other_device.id}

      view
      |> render_hook(:delete_device, params)

      flash = assert_redirected(view, Routes.session_new_path(conn, :new))
      assert flash["error"] == "Not authorized."
    end
  end

  describe "allowlist" do
    setup :create_allow_rule

    @destination "1.2.3.4"
    @allow_params %{"action" => "allow", "destination" => @destination}

    def allow_params(device_id) do
      %{"rule" => Map.merge(@allow_params, %{"device_id" => device_id})}
    end

    test "adds to allowlist", %{authed_conn: conn, rule: rule} do
      path = Routes.device_show_path(conn, :show, rule.device_id)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#allow-form")
        |> render_submit(allow_params(rule.device_id))

      assert test_view =~ @destination
    end

    test "removes from allowlist", %{authed_conn: conn, rule: rule} do
      path = Routes.device_show_path(conn, :show, rule.device_id)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("a[phx-value-rule_id=#{rule.id}]")
        |> render_click()

      refute test_view =~ "#{rule.destination}"
    end
  end

  describe "denylist" do
    setup :create_deny_rule

    @destination "1.2.3.4"
    @deny_params %{"action" => "deny", "destination" => @destination}

    def deny_params(device_id) do
      %{"rule" => Map.merge(@deny_params, %{"device_id" => device_id})}
    end

    test "adds to denylist", %{authed_conn: conn, rule: rule} do
      path = Routes.device_show_path(conn, :show, rule.device_id)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> form("#deny-form")
        |> render_submit(deny_params(rule.device_id))

      assert test_view =~ @destination
    end

    test "removes from denylist", %{authed_conn: conn, rule: rule} do
      path = Routes.device_show_path(conn, :show, rule.device_id)
      {:ok, view, _html} = live(conn, path)

      test_view =
        view
        |> element("a[phx-value-rule_id=#{rule.id}]")
        |> render_click()

      refute test_view =~ "#{rule.destination}"
    end
  end

  describe "unauthenticated" do
    setup :create_device

    test "mount redirects to session path", %{unauthed_conn: conn, device: device} do
      path = Routes.device_show_path(conn, :show, device)
      expected_path = Routes.session_new_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end

  describe "authenticated as other user" do
    setup [:create_device, :create_other_user_device]

    test "mount redirects to session path", %{
      authed_conn: conn,
      device: _device,
      other_device: other_device
    } do
      path = Routes.device_show_path(conn, :show, other_device)
      expected_path = Routes.session_new_path(conn, :new)
      assert {:error, {:redirect, %{to: ^expected_path}}} = live(conn, path)
    end
  end
end
