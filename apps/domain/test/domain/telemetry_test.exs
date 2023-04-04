defmodule Domain.TelemetryTest do
  use Domain.DataCase, async: true
  import Domain.TestHelpers
  alias Domain.Telemetry
  alias Domain.MFAFixtures

  describe "user" do
    setup :create_user

    test "count" do
      ping_data = Telemetry.ping_data()

      assert ping_data[:user_count] == 1
    end

    test "count mfa", %{user: user} do
      {:ok, [user: other_user]} = create_user(%{})
      MFAFixtures.create_totp_method(user: user)
      MFAFixtures.create_totp_method(user: other_user)
      ping_data = Telemetry.ping_data()

      assert ping_data[:users_with_mfa] == 2
      assert ping_data[:users_with_mfa_totp] == 2
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
      Domain.ConfigFixtures.start_openid_providers([
        "google",
        "okta",
        "auth0",
        "azure",
        "onelogin",
        "keycloak",
        "vault"
      ])

      ping_data = Telemetry.ping_data()

      assert ping_data[:openid_providers] == 7
    end

    test "disable vpn on oidc error enabled" do
      Domain.Config.put_config!(:disable_vpn_on_oidc_error, true)

      ping_data = Telemetry.ping_data()

      assert ping_data[:disable_vpn_on_oidc_error]
    end

    test "disable vpn on oidc error disabled" do
      Domain.Config.put_config!(:disable_vpn_on_oidc_error, false)

      ping_data = Telemetry.ping_data()

      refute ping_data[:disable_vpn_on_oidc_error]
    end

    test "local authentication enabled" do
      Domain.Config.put_config!(:local_auth_enabled, true)

      ping_data = Telemetry.ping_data()

      assert ping_data[:local_authentication]
    end

    test "local authentication disabled" do
      Domain.Config.put_config!(:local_auth_enabled, false)

      ping_data = Telemetry.ping_data()

      refute ping_data[:local_authentication]
    end

    test "unprivileged device management enabled" do
      Domain.Config.put_config!(:allow_unprivileged_device_management, true)

      ping_data = Telemetry.ping_data()

      assert ping_data[:unprivileged_device_management]
    end

    test "unprivileged device configuration enabled" do
      Domain.Config.put_config!(:allow_unprivileged_device_configuration, true)

      ping_data = Telemetry.ping_data()

      assert ping_data[:unprivileged_device_configuration]
    end

    test "unprivileged device configuration disabled" do
      Domain.Config.put_config!(:allow_unprivileged_device_configuration, false)

      ping_data = Telemetry.ping_data()

      refute ping_data[:unprivileged_device_configuration]
    end
  end

  describe "database" do
    test "local hostname" do
      Domain.Config.put_env_override(:domain, Domain.Repo, hostname: "localhost")

      ping_data = Telemetry.ping_data()

      refute ping_data[:external_database]
    end

    test "local url" do
      Domain.Config.put_env_override(:domain, Domain.Repo, url: "postgres://127.0.0.1")

      ping_data = Telemetry.ping_data()

      refute ping_data[:external_database]
    end

    test "external hostname" do
      Domain.Config.put_env_override(:domain, Domain.Repo, hostname: "firezone.dev")

      ping_data = Telemetry.ping_data()

      assert ping_data[:external_database]
    end

    test "external url" do
      Domain.Config.put_env_override(:domain, Domain.Repo, url: "postgres://firezone.dev")

      ping_data = Telemetry.ping_data()

      assert ping_data[:external_database]
    end
  end

  describe "email" do
    test "outbound set" do
      Domain.Config.put_env_override(:domain, Web.Mailer,
        adapter: Swoosh.Adapters.NoopAdapter,
        from_email: "test@firezone.dev"
      )

      ping_data = Telemetry.ping_data()

      assert ping_data[:outbound_email]
    end

    test "outbound unset" do
      Domain.Config.put_env_override(:domain, Web.Mailer,
        adapter: SwooshAdapters.NoopAdapter,
        from_email: nil
      )

      ping_data = Telemetry.ping_data()

      assert ping_data[:outbound_email] == Web.MailerTestAdapter
    end
  end
end
