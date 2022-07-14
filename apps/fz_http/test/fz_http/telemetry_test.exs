defmodule FzHttp.TelemetryTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Telemetry

  describe "user" do
    setup :create_user

    test "count" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:user_count] == 1
    end

    test "count mfa", %{user: user} do
      {:ok, [user: other_user]} = create_user(%{})
      {:ok, _method} = create_method(user, type: :totp)
      {:ok, _method} = create_method(other_user, type: :portable)
      ping_data = Telemetry.ping_data()

      assert ping_data[:users_with_mfa] == 2
      assert ping_data[:users_with_mfa_totp] == 1
    end
  end

  describe "device" do
    setup [:create_devices, :create_other_user_device]

    test "count" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:device_count] == 6
    end

    test "max count for users" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:max_devices_for_users] == 5
    end
  end

  describe "auth" do
    test "count openid providers" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:openid_providers] == 2
    end

    test "auto create oidc users" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:auto_create_oidc_users]
    end

    test "disable vpn on oidc error" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:disable_vpn_on_oidc_error]
    end

    test "local authentication" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:local_authentication]
    end

    test "unprivileged device management" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:unprivileged_device_management]
    end
  end

  test "external database" do
    ping_data = Telemetry.ping_data()

    assert !ping_data[:external_database]
  end

  test "outbound email" do
    ping_data = Telemetry.ping_data()

    assert ping_data[:outbound_email]
  end
end
