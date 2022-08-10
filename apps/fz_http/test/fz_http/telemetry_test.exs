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
    setup context do
      if context[:config] do
        {key, value} = context[:config]
        restore_env(key, value, &on_exit/1)
      else
        context
      end
    end

    test "count openid providers" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:openid_providers] == 2
    end

    @tag config: {:auto_create_oidc_users, true}
    test "auto create oidc users enabled" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:auto_create_oidc_users]
    end

    @tag config: {:auto_create_oidc_users, false}
    test "auto create oidc users disabled" do
      ping_data = Telemetry.ping_data()

      refute ping_data[:auto_create_oidc_users]
    end

    @tag config: {:disable_vpn_on_oidc_error, true}
    test "disable vpn on oidc error enabled" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:disable_vpn_on_oidc_error]
    end

    @tag config: {:disable_vpn_on_oidc_error, false}
    test "disable vpn on oidc error disabled" do
      ping_data = Telemetry.ping_data()

      refute ping_data[:disable_vpn_on_oidc_error]
    end

    @tag config: {:local_auth_enabled, true}
    test "local authentication enabled" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:local_authentication]
    end

    @tag config: {:local_auth_enabled, false}
    test "local authentication disabled" do
      ping_data = Telemetry.ping_data()

      refute ping_data[:local_authentication]
    end

    @tag config: {:allow_unprivileged_device_management, true}
    test "unprivileged device management enabled" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:unprivileged_device_management]
    end

    @tag config: {:allow_unprivileged_device_configuration, true}
    test "unprivileged device configuration enabled" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:unprivileged_device_configuration]
    end

    @tag config: {:allow_unprivileged_device_configuration, false}
    test "unprivileged device configuration disabled" do
      ping_data = Telemetry.ping_data()

      refute ping_data[:unprivileged_device_configuration]
    end
  end

  describe "database" do
    setup context do
      restore_env(FzHttp.Repo, context[:db_config], &on_exit/1)
    end

    @tag db_config: [hostname: "localhost"]
    test "local hostname" do
      ping_data = Telemetry.ping_data()

      refute ping_data[:external_database]
    end

    @tag db_config: [url: "postgres://127.0.0.1"]
    test "local url" do
      ping_data = Telemetry.ping_data()

      refute ping_data[:external_database]
    end

    @tag db_config: [hostname: "firezone.dev"]
    test "external hostname" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:external_database]
    end

    @tag db_config: [url: "postgres://firezone.dev"]
    test "external url" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:external_database]
    end
  end

  describe "email" do
    setup context do
      restore_env(FzHttp.Mailer, [from_email: context[:from_email]], &on_exit/1)
    end

    @tag from_email: "test@firezone.dev"
    test "outbound set" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:outbound_email]
    end

    @tag from_email: nil
    test "outbound unset" do
      ping_data = Telemetry.ping_data()

      refute ping_data[:outbound_email]
    end
  end
end
