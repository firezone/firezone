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
    # create new user without password
    # create new local authenticated user
    # see user details (Last Signed In, Number of Devices, Number of Rules, etc, Devices list)
    # disable user VPN connection
    # promote unprivileged user to admin
    # demote admin to unprivileged user
    # delete user
    # change user email
    # change user password
    # add device to user
  end

  describe "device management" do
    feature "can add devices", %{session: session} do
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
      |> fill_in(Query.fillable_field("device[allowed_ips]"), with: "127.0.0.1")
      |> fill_form(%{
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
      |> click(Query.css("button[phx-click=\"close\"]"))
      |> assert_el(Query.link("Add Device"))
      |> assert_el(Query.link("big-leg-007"))

      assert device = Repo.one(FzHttp.Devices.Device)
      assert device.name == "big-leg-007"
      assert device.description == "Dummy description"
      assert device.allowed_ips == "127.0.0.1"
      assert device.dns == "1.1.1.1,2.2.2.2"
      assert device.endpoint == "example.com:51820"
      assert device.mtu == 1400
      assert device.persistent_keepalive == 10
      assert device.ipv4 == %Postgrex.INET{address: {10, 10, 11, 1}}
      assert device.ipv6 == %Postgrex.INET{address: {64768, 0, 0, 0, 0, 0, 30, 16278}}
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
    # create new allow rule
    # create new allow rule for a specific user
    # create new TCP allow rule for a given port range
    # delete allow rules
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

      assert configuration = FzHttp.Configurations.get_configuration!()
      assert configuration.default_client_persistent_keepalive == 10
      assert configuration.default_client_mtu == 1234
      assert configuration.default_client_endpoint == "example.com:8123"
      assert configuration.default_client_dns == "1.1.1.1,2.2.2.2"
      assert configuration.default_client_allowed_ips == "192.0.0.0/0,::/0"
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

      assert configuration = FzHttp.Configurations.get_configuration!()
      assert configuration.logo.url == "https://http.cat/200"
    end
  end

  describe "security" do
    # enforce VPN session authentication
    # enable and disable local auth
    # allow unprivileged device management
    # allow unprivileged device configuration
    # enable and disable auto disable VPN

    # add new OIDC provider
    # edit OIDC provider
    # remove OIDC provider

    # add new SAML provider
    # edit SAML provider
    # remove SAML provider
  end

  # describe "profile" do
  #   feature "allows to change password", %{
  #     session: session
  #   } do
  #     user = UsersFixtures.create_user_with_role(:admin)

  #     session =
  #       session
  #       |> visit(~p"/")
  #       |> Auth.authenticate(user)
  #       |> visit(~p"/user_devices")
  #       |> assert_el(Query.text("Your Devices"))
  #       |> click(Query.link("My Account"))
  #       |> assert_el(Query.text("Account Settings"))
  #       |> click(Query.link("Change Password"))
  #       |> assert_el(Query.text("Enter new password below."))
  #       |> fill_in(Query.fillable_field("user[password]"), with: "foo")
  #       |> fill_in(Query.fillable_field("user[password_confirmation]"), with: "")
  #       |> click(Query.button("Save"))
  #       |> assert_el(Query.text("should be at least 12 character(s)"))
  #       |> assert_el(Query.text("does not match confirmation"))

  #     # Make sure form only contains two inputs
  #     find(session, Query.css(".input", count: 2))

  #     session
  #     |> fill_in(Query.fillable_field("user[password]"), with: "new_password")
  #     |> fill_in(Query.fillable_field("user[password_confirmation]"), with: "new_password")
  #     |> click(Query.button("Save"))
  #     |> assert_el(Query.text("Password updated successfully"))

  #     assert Repo.one(FzHttp.Users.User).password_hash != user.password_hash
  #   end
  # change email
  # see active session
  # delete own account

  # end

  describe "api tokens" do
    # create and use token using curl
    # see created token secret
    # delete token
  end
end
