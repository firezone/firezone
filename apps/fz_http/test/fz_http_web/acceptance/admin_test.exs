defmodule FzHttpWeb.Acceptance.AdminTest do
  use FzHttpWeb.AcceptanceCase, async: true
  alias FzHttp.UsersFixtures
  alias FzHttp.DevicesFixtures

  setup tags do
    user = UsersFixtures.create_user_with_role(:admin)

    session =
      tags.session
      |> visit(~p"/")
      |> Auth.authenticate(user)

    tags
    |> Map.put(:session, session)
    |> Map.put(:user, user)
  end

  describe "user management" do
    feature "create new unprivileged users without password", %{session: session, user: user} do
      attrs = UsersFixtures.user_attrs()

      session
      |> visit(~p"/users/new")
      |> assert_el(Query.text("Add User", minimum: 1))
      |> fill_in(Query.fillable_field("user[email]"), with: "xxx")
      |> click(Query.button("Save"))
      |> assert_el(Query.text("is invalid email address"))
      |> fill_in(Query.fillable_field("user[email]"), with: user.email)
      |> click(Query.button("Save"))
      |> assert_el(Query.text("has already been taken"))
      |> fill_in(Query.fillable_field("user[email]"), with: attrs.email)
      |> click(Query.button("Save"))
      |> assert_el(Query.text("User created successfully."))
      |> assert_el(Query.text(attrs.email, minimum: 1))

      assert Repo.get_by(FzHttp.Users.User, email: attrs.email)
    end

    feature "create new unprivileged users with password auth", %{session: session, user: user} do
      attrs = UsersFixtures.user_attrs()

      session
      |> visit(~p"/users/new")
      |> assert_el(Query.text("Add User", minimum: 1))
      |> fill_form(%{
        "user[email]" => "xxx",
        "user[password]" => "yyy",
        "user[password_confirmation]" => "zzz"
      })
      |> click(Query.button("Save"))
      |> assert_el(Query.text("is invalid email address"))
      |> assert_el(Query.text("should be at least 12 character(s)"))
      |> assert_el(Query.text("does not match confirmation"))
      |> fill_form(%{
        "user[email]" => user.email,
        "user[password]" => "firezone1234",
        "user[password_confirmation]" => "firezone1234"
      })
      |> click(Query.button("Save"))
      |> assert_el(Query.text("has already been taken"))
      # XXX: for some reason form rests when email has already been taken
      |> fill_form(%{
        "user[email]" => attrs.email,
        "user[password]" => attrs.password,
        "user[password_confirmation]" => attrs.password_confirmation
      })
      |> click(Query.button("Save"))
      |> assert_el(Query.text("User created successfully."))
      |> assert_el(Query.text("unprivileged", minimum: 1))
      |> assert_el(Query.text(attrs.email, minimum: 1))

      assert user = Repo.get_by(FzHttp.Users.User, email: attrs.email)
      assert user.role == :unprivileged
      assert FzCommon.FzCrypto.equal?(attrs.password, user.password_hash)
    end

    feature "change user email and password", %{session: session} do
      user = UsersFixtures.create_user_with_role(:admin)

      session
      |> visit(~p"/users/#{user.id}")
      |> assert_el(Query.link("Change Email or Password"))
      |> click(Query.link("Change Email or Password"))
      |> assert_el(Query.text("Change user email or enter new password below."))
      |> fill_form(%{
        "user[email]" => "foo",
        "user[password]" => "123",
        "user[password_confirmation]" => "1234"
      })
      |> click(Query.button("Save"))
      |> assert_el(Query.text("is invalid email address"))
      |> assert_el(Query.text("should be at least 12 character(s)"))
      |> assert_el(Query.text("does not match confirmation"))
      |> fill_form(%{
        "user[email]" => "foo@xample.com",
        "user[password]" => "mynewpassword",
        "user[password_confirmation]" => "mynewpassword"
      })
      |> click(Query.button("Save"))
      |> assert_el(Query.text("User updated successfully."))

      assert updated_user = Repo.get(FzHttp.Users.User, user.id)
      assert updated_user.password_hash != user.password_hash
      assert updated_user.email == "foo@xample.com"
    end

    feature "promote and demote users", %{session: session} do
      user = UsersFixtures.create_user_with_role(:admin)

      session =
        session
        |> visit(~p"/users/#{user.id}")
        |> assert_el(Query.link("Change Email or Password"))

      accept_confirm(session, fn session ->
        session
        |> click(Query.button("demote"))
        |> assert_el(Query.text("User updated successfully."))
      end)

      assert updated_user = Repo.get(FzHttp.Users.User, user.id)
      assert updated_user.role == :unprivileged

      accept_confirm(session, fn session ->
        session
        |> click(Query.button("promote"))
        |> assert_el(Query.text("User updated successfully."))
      end)

      assert updated_user = Repo.get(FzHttp.Users.User, user.id)
      assert updated_user.role == :admin
    end

    feature "disable and enable user VPN connection", %{session: session} do
      user = UsersFixtures.create_user_with_role(:admin)

      session =
        session
        |> visit(~p"/users/#{user.id}")
        |> assert_el(Query.link("Change Email or Password"))

      accept_confirm(session, fn session ->
        session
        |> toggle("toggle_disabled_at")
      end)

      wait_for(fn ->
        assert updated_user = Repo.get(FzHttp.Users.User, user.id)
        refute is_nil(updated_user.disabled_at)
      end)

      accept_confirm(session, fn session ->
        session
        |> toggle("toggle_disabled_at")
      end)

      wait_for(fn ->
        assert updated_user = Repo.get(FzHttp.Users.User, user.id)
        assert is_nil(updated_user.disabled_at)
      end)
    end

    feature "delete user", %{session: session, user: user} do
      unprivileged_user = UsersFixtures.create_user_with_role(:unprivileged)

      session =
        session
        |> visit(~p"/users/#{user.id}")
        |> assert_el(Query.button("Delete User"))

      accept_confirm(session, fn session ->
        click(session, Query.button("Delete User"))
      end)

      assert_el(session, Query.text("Use the account section to delete your account."))

      assert Repo.get(FzHttp.Users.User, user.id)

      session
      |> visit(~p"/users/#{unprivileged_user.id}")
      |> assert_el(Query.button("Delete User"))

      accept_confirm(session, fn session ->
        click(session, Query.button("Delete User"))
      end)

      assert_el(session, Query.text("User deleted successfully."))

      refute Repo.get(FzHttp.Users.User, unprivileged_user.id)
    end
  end

  describe "device management" do
    feature "can add devices for users", %{session: session} do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session
      |> visit(~p"/users/#{user.id}")
      |> assert_el(Query.text("No devices."))
      |> assert_el(Query.link("Add Device"))
      |> click(Query.link("Add Device"))
      |> assert_el(Query.button("Generate Configuration"))
      |> set_value(Query.css("#create-device_use_default_allowed_ips_false"), :selected)
      |> set_value(Query.css("#create-device_use_default_dns_false"), :selected)
      |> set_value(Query.css("#create-device_use_default_endpoint_false"), :selected)
      |> set_value(Query.css("#create-device_use_default_mtu_false"), :selected)
      |> set_value(
        Query.css("#create-device_use_default_persistent_keepalive_false"),
        :selected
      )
      |> fill_form(%{
        "device[allowed_ips]" => "127.0.0.1",
        "device[name]" => "big-leg-007",
        "device[description]" => "Dummy description",
        "device[dns]" => "1.1.1.1,2.2.2.2",
        "device[endpoint]" => "example.com:51820",
        "device[mtu]" => "1400",
        "device[persistent_keepalive]" => "10",
        "device[ipv4]" => "10.10.11.1",
        "device[ipv6]" => "fd00::1e:3f96"
      })
      |> click(Query.button("Generate Configuration"))
      |> assert_el(Query.text("Device added!"))
      |> click(Query.css("#download-config"))
      |> click(Query.css("button[phx-click=\"close\"]"))
      |> assert_el(Query.link("Add Device"))
      |> assert_el(Query.link("big-leg-007"))
      |> assert_path(~p"/users/#{user.id}")

      assert device = Repo.one(FzHttp.Devices.Device)
      assert device.name == "big-leg-007"
      assert device.description == "Dummy description"
      assert device.allowed_ips == [%Postgrex.INET{address: {127, 0, 0, 1}, netmask: nil}]
      assert device.dns == ["1.1.1.1", "2.2.2.2"]
      assert device.endpoint == "example.com:51820"
      assert device.mtu == 1400
      assert device.persistent_keepalive == 10
      assert device.ipv4 == %Postgrex.INET{address: {10, 10, 11, 1}}
      assert device.ipv6 == %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 30, 16_278}}
    end

    feature "can see devices, their details and delete them", %{session: session} do
      device1 = DevicesFixtures.device()
      device2 = DevicesFixtures.device()

      session =
        session
        |> visit(~p"/devices")
        |> assert_el(Query.text("All Devices"))
        |> assert_el(Query.link(device1.name))
        |> click(Query.link(device2.name))
        |> assert_el(Query.text("Danger Zone"))
        |> assert_el(Query.text(device2.public_key))

      accept_confirm(session, fn session ->
        click(session, Query.button("Delete Device #{device2.name}"))
      end)

      assert_el(session, Query.text("All Devices"))

      assert Repo.aggregate(FzHttp.Devices.Device, :count) == 1
    end
  end

  describe "rules" do
    feature "manage allow rules", %{session: session, user: user} do
      session =
        session
        |> visit(~p"/rules")
        |> assert_has(Query.text("Egress Rules"))
        |> find(Query.css("#accept-form"), fn parent ->
          parent
          |> set_value(Query.select("rule[port_type]"), "tcp")
          |> set_value(Query.select("rule[user_id]"), user.email)
          |> fill_form(%{
            "rule[destination]" => "8.8.4.4",
            "rule[port_range]" => "1-8000"
          })
          |> click(Query.button("Add"))
        end)
        |> assert_has(Query.text("8.8.4.4"))
        |> assert_has(Query.link("Delete"))

      assert rule = Repo.one(FzHttp.Rules.Rule)
      assert rule.destination == %Postgrex.INET{address: {8, 8, 4, 4}}
      assert rule.port_range == "1 - 8000"
      assert rule.port_type == :tcp

      click(session, Query.link("Delete"))

      # XXX: We need to show a confirmation dialog on delete,
      # and message once record was saved or deleted.
      wait_for(fn ->
        assert is_nil(Repo.one(FzHttp.Rules.Rule))
      end)
    end
  end

  describe "settings" do
    feature "change default settings", %{session: session} do
      session
      |> visit(~p"/settings/client_defaults")
      |> assert_el(Query.text("Client Defaults", count: 2))
      |> fill_form(%{
        "configuration[default_client_allowed_ips]" => "192.0.0.0/0,::/0",
        "configuration[default_client_dns]" => "1.1.1.1,2.2.2.2",
        "configuration[default_client_endpoint]" => "example.com:8123",
        "configuration[default_client_persistent_keepalive]" => "10",
        "configuration[default_client_mtu]" => "1234"
      })
      |> click(Query.button("Save"))
      # XXX: We need to show a flash that settings are saved
      |> visit(~p"/settings/client_defaults")
      |> assert_el(Query.text("Client Defaults", count: 2))

      assert configuration = FzHttp.Config.fetch_db_config!()
      assert configuration.default_client_persistent_keepalive == 10
      assert configuration.default_client_mtu == 1234
      assert configuration.default_client_endpoint == "example.com:8123"
      assert configuration.default_client_dns == ["1.1.1.1", "2.2.2.2"]

      assert configuration.default_client_allowed_ips == [
               %Postgrex.INET{address: {192, 0, 0, 0}, netmask: 0},
               %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 0}, netmask: 0}
             ]
    end
  end

  describe "customization" do
    feature "allows to change logo using a URL", %{session: session} do
      session
      |> visit(~p"/settings/customization")
      |> assert_el(Query.text("Customization", count: 2))
      |> set_value(Query.css("input[value=\"URL\"]"), :selected)
      |> fill_in(Query.fillable_field("url"), with: "https://http.cat/200")
      |> click(Query.button("Save"))
      |> assert_el(Query.css("img[src=\"https://http.cat/200\"]"))

      assert configuration = FzHttp.Config.fetch_db_config!()
      assert configuration.logo.url == "https://http.cat/200"
    end
  end

  describe "security" do
    @tag :debug
    feature "change security settings", %{
      session: session
    } do
      assert configuration = FzHttp.Config.fetch_db_config!()
      assert configuration.local_auth_enabled == true
      assert configuration.allow_unprivileged_device_management == true
      assert configuration.allow_unprivileged_device_configuration == true
      assert configuration.disable_vpn_on_oidc_error == false

      session
      |> visit(~p"/settings/security")
      |> assert_el(Query.text("Security Settings"))
      |> toggle("local_auth_enabled")
      |> toggle("allow_unprivileged_device_management")
      |> toggle("allow_unprivileged_device_configuration")
      |> toggle("disable_vpn_on_oidc_error")
      |> assert_el(Query.text("Security Settings"))

      assert configuration = FzHttp.Config.fetch_db_config!()
      assert configuration.local_auth_enabled == false
      assert configuration.allow_unprivileged_device_management == false
      assert configuration.allow_unprivileged_device_configuration == false
      assert configuration.disable_vpn_on_oidc_error == true
    end

    feature "change required authentication timeout", %{session: session} do
      assert configuration = FzHttp.Config.fetch_db_config!()
      assert configuration.vpn_session_duration == 0

      session
      |> visit(~p"/settings/security")
      |> assert_el(Query.text("Security Settings"))
      |> find(Query.select("configuration[vpn_session_duration]"), fn select ->
        click(select, Query.option("Every Week"))
      end)
      |> click(Query.css("[type=\"submit\""))
      |> assert_el(Query.text("Security Settings"))

      # XXX: We need to show a flash that settings are saved
      wait_for(fn ->
        assert configuration = FzHttp.Config.fetch_db_config!()
        assert configuration.vpn_session_duration == 604_800
      end)
    end

    feature "manage OpenIDConnect providers", %{session: session} do
      {_bypass, uri} = FzHttp.ConfigFixtures.discovery_document_server()

      # Create
      session =
        session
        |> visit(~p"/settings/security")
        |> assert_el(Query.text("Security Settings"))
        |> click(Query.link("Add OpenID Connect Provider"))
        |> assert_el(Query.text("OIDC Configuration"))
        |> fill_in(Query.fillable_field("open_id_connect_provider[id]"), with: "oidc-foo-bar")
        |> fill_in(Query.fillable_field("open_id_connect_provider[label]"), with: "Firebook")
        |> fill_in(Query.fillable_field("open_id_connect_provider[scope]"),
          with: "openid email eyes_color"
        )
        |> fill_in(Query.fillable_field("open_id_connect_provider[client_id]"), with: "CLIENT_ID")
        |> fill_in(Query.fillable_field("open_id_connect_provider[client_secret]"),
          with: "CLIENT_SECRET"
        )
        |> fill_in(Query.fillable_field("open_id_connect_provider[discovery_document_uri]"),
          with: uri
        )
        |> fill_in(Query.fillable_field("open_id_connect_provider[redirect_uri]"),
          with: "http://localhost/redirect"
        )
        |> toggle("open_id_connect_provider[auto_create_users]")
        |> click(Query.css("button[form=\"oidc-form\"]"))
        |> assert_el(Query.text("Updated successfully."))
        |> assert_el(Query.text("oidc-foo-bar"))
        |> assert_el(Query.text("Firebook"))

      assert [open_id_connect_provider] = FzHttp.Config.fetch_config!(:openid_connect_providers)

      assert open_id_connect_provider ==
               %FzHttp.Config.Configuration.OpenIDConnectProvider{
                 id: "oidc-foo-bar",
                 label: "Firebook",
                 scope: "openid email eyes_color",
                 response_type: "code",
                 client_id: "CLIENT_ID",
                 client_secret: "CLIENT_SECRET",
                 discovery_document_uri: uri,
                 redirect_uri: "http://localhost/redirect",
                 auto_create_users: true
               }

      # Edit
      session =
        session
        |> click(Query.link("Edit"))
        |> assert_el(Query.text("OIDC Configuration"))
        |> fill_in(Query.fillable_field("open_id_connect_provider[label]"), with: "Metabook")
        |> click(Query.css("button[form=\"oidc-form\"]"))
        |> assert_el(Query.text("Updated successfully."))
        |> assert_el(Query.text("Metabook"))

      assert [open_id_connect_provider] = FzHttp.Config.fetch_config!(:openid_connect_providers)
      assert open_id_connect_provider.label == "Metabook"

      # Delete
      accept_confirm(session, fn session ->
        click(session, Query.button("Delete"))
      end)

      assert_el(session, Query.text("Updated successfully."))

      assert FzHttp.Config.fetch_config!(:openid_connect_providers) == []
    end

    feature "manage SAML providers", %{session: session} do
      saml_metadata = FzHttp.SAMLIdentityProviderFixtures.metadata()

      # Create
      session =
        session
        |> visit(~p"/settings/security")
        |> assert_el(Query.text("Security Settings"))
        |> click(Query.link("Add SAML Identity Provider"))
        |> assert_el(Query.text("SAML Configuration"))
        |> toggle("saml_identity_provider[sign_requests]")
        |> toggle("saml_identity_provider[sign_metadata]")
        |> toggle("saml_identity_provider[signed_assertion_in_resp]")
        |> toggle("saml_identity_provider[signed_envelopes_in_resp]")
        |> toggle("saml_identity_provider[auto_create_users]")
        |> fill_in(Query.fillable_field("saml_identity_provider[id]"), with: "foo-bar-buz")
        |> fill_in(Query.fillable_field("saml_identity_provider[label]"), with: "Sneaky ID")
        |> fill_in(Query.fillable_field("saml_identity_provider[base_url]"),
          with: "http://localhost:4002/autX/saml#foo"
        )
        |> fill_in(Query.fillable_field("saml_identity_provider[metadata]"),
          with: saml_metadata
        )
        |> click(Query.css("button[form=\"saml-form\"]"))
        |> assert_el(Query.text("Updated successfully."))
        |> assert_el(Query.text("foo-bar-buz"))
        |> assert_el(Query.text("Sneaky ID"))

      assert [saml_identity_provider] = FzHttp.Config.fetch_config!(:saml_identity_providers)

      assert saml_identity_provider ==
               %FzHttp.Config.Configuration.SAMLIdentityProvider{
                 id: "foo-bar-buz",
                 label: "Sneaky ID",
                 base_url: "http://localhost:4002/autX/saml#foo",
                 metadata: saml_metadata,
                 sign_requests: false,
                 sign_metadata: false,
                 signed_assertion_in_resp: false,
                 signed_envelopes_in_resp: false,
                 auto_create_users: true
               }

      # Edit
      session =
        session
        |> click(Query.link("Edit"))
        |> assert_el(Query.text("SAML Configuration"))
        |> fill_in(Query.fillable_field("saml_identity_provider[label]"), with: "Sneaky XID")
        |> click(Query.css("button[form=\"saml-form\"]"))
        |> assert_el(Query.text("Updated successfully."))
        |> assert_el(Query.text("Sneaky XID"))

      assert [saml_identity_provider] = FzHttp.Config.fetch_config!(:saml_identity_providers)
      assert saml_identity_provider.label == "Sneaky XID"

      # Delete
      accept_confirm(session, fn session ->
        click(session, Query.button("Delete"))
      end)

      assert_el(session, Query.text("Updated successfully."))

      assert FzHttp.Config.fetch_config!(:saml_identity_providers) == []
    end
  end

  describe "profile" do
    feature "edit profile", %{
      session: session,
      user: user
    } do
      session
      |> visit(~p"/settings/account")
      |> assert_el(Query.link("Change Email or Password"))
      |> click(Query.link("Change Email or Password"))
      |> assert_el(Query.text("Edit Account"))
      |> fill_form(%{
        "user[email]" => "foo",
        "user[password]" => "123",
        "user[password_confirmation]" => "1234"
      })
      |> click(Query.button("Save"))
      |> assert_el(Query.text("is invalid email address"))
      |> assert_el(Query.text("should be at least 12 character(s)"))
      |> assert_el(Query.text("does not match confirmation"))
      |> fill_form(%{
        "user[email]" => "foo@xample.com",
        "user[password]" => "mynewpassword",
        "user[password_confirmation]" => "mynewpassword"
      })
      |> click(Query.button("Save"))
      |> assert_el(Query.text("Account updated successfully."))

      assert updated_user = Repo.one(FzHttp.Users.User)
      assert updated_user.password_hash != user.password_hash
      assert updated_user.email == "foo@xample.com"
    end

    feature "can see active user sessions", %{
      session: session,
      user_agent: user_agent
    } do
      session
      |> visit(~p"/settings/account")
      |> assert_el(Query.text("Active Sessions"))
      |> assert_el(Query.text(user_agent))
    end

    feature "can delete own account if there are other admins", %{session: session} do
      session =
        session
        |> visit(~p"/settings/account")
        |> assert_el(Query.text("Danger Zone"))

      assert attr(session, Query.button("Delete Your Account"), "disabled") ==
               "true"

      UsersFixtures.create_user_with_role(:admin)

      session =
        session
        |> visit(~p"/settings/account")
        |> assert_el(Query.text("Danger Zone"))

      accept_confirm(session, fn session ->
        click(session, Query.button("Delete Your Account"))
      end)

      session
      |> Auth.assert_unauthenticated()
      |> assert_path("/")
    end
  end

  describe "api tokens" do
    feature "create, use using curl and delete API tokens", %{
      session: session,
      user: user,
      user_agent: user_agent
    } do
      session =
        session
        |> visit(~p"/settings/account")
        |> assert_el(Query.text("API Tokens"))
        |> assert_el(Query.text("No API tokens."))
        |> click(Query.css("[href=\"/settings/account/api_token\"]"))
        |> assert_el(Query.text("Add API Token", minimum: 1))
        |> fill_form(%{
          "api_token[expires_in]" => 1
        })
        |> click(Query.button("Save"))
        |> assert_el(Query.text("API token secret:"))

      api_token_secret = text(session, Query.css("#api-token-secret"))
      curl_example = text(session, Query.css("#api-usage-example"))
      curl_example = String.replace(curl_example, ~r/^.*curl/is, "curl")

      assert String.contains?(curl_example, api_token_secret)
      assert api_token = Repo.one(FzHttp.ApiTokens.ApiToken)
      assert api_token.user_id == user.id

      args =
        curl_example
        |> String.trim_leading("curl ")
        |> String.replace("\\\n", "")
        |> String.replace(~r/[ ]+/, " ")
        |> String.replace("'", "")
        |> String.split(" ")
        |> curl_args([])

      args = ["-s", "-H", "User-Agent:#{user_agent}"] ++ args
      {resp, _} = System.cmd("curl", args, stderr_to_stdout: true)

      assert %{"data" => [%{"id" => user_id}]} = Jason.decode!(resp)
      assert user_id == user.id

      session =
        session
        |> click(Query.css("button[aria-label=\"close\"]"))
        |> assert_el(Query.text("API Tokens"))
        |> assert_el(Query.link("Delete"))
        |> click(Query.link(api_token.id))
        |> assert_el(Query.text("API token secret:"))
        |> click(Query.css("button[aria-label=\"close\"]"))
        |> assert_el(Query.link("Delete"))
        |> assert_path(~p"/settings/account")

      accept_confirm(session, fn session ->
        click(session, Query.link("Delete"))
      end)

      assert_el(session, Query.text("No API tokens."))

      assert is_nil(Repo.one(FzHttp.ApiTokens.ApiToken))
    end
  end

  defp curl_args([], acc) do
    acc
  end

  defp curl_args(["-H", header, "Bearer", token | rest], acc) do
    acc = acc ++ ["-H", "#{header}Bearer #{token}"]
    curl_args(rest, acc)
  end

  defp curl_args(["-H", header, value | rest], acc) do
    acc = acc ++ ["-H", "#{header}#{value}"]
    curl_args(rest, acc)
  end

  defp curl_args(["http" <> _ = url | rest], acc) do
    acc = acc ++ [url]
    curl_args(rest, acc)
  end

  defp curl_args([other | rest], acc) do
    curl_args(rest, acc ++ [other])
  end
end
