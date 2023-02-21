defmodule FzHttpWeb.Acceptance.UnprivilegedUserTest do
  use FzHttpWeb.AcceptanceCase, async: true
  alias FzHttp.{UsersFixtures, DevicesFixtures}

  describe "device management" do
    setup tags do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session =
        tags.session
        |> visit(~p"/")
        |> Auth.authenticate(user)

      tags
      |> Map.put(:session, session)
      |> Map.put(:user, user)
    end

    feature "allows user to add and configure a device", %{
      session: session
    } do
      FzHttp.Config.put_config!(:allow_unprivileged_device_configuration, true)

      session
      |> visit(~p"/user_devices")
      |> assert_el(Query.text("Your Devices"))
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
        "device[name]" => "big-head-007",
        "device[description]" => "Dummy description",
        "device[dns]" => "1.1.1.1,2.2.2.2",
        "device[endpoint]" => "example.com:51820",
        "device[mtu]" => "1400",
        "device[persistent_keepalive]" => "10",
        "device[ipv4]" => "10.10.11.1",
        "device[ipv6]" => "fd00::1e:3f96"
      })
      |> fill_in(Query.fillable_field("device[description]"), with: "Dummy description")
      |> click(Query.button("Generate Configuration"))
      |> assert_el(Query.text("Device added!"))
      |> click(Query.css("button[phx-click=\"close\"]"))
      |> assert_el(Query.text("big-head-007"))
      |> assert_path(~p"/user_devices")

      assert device = Repo.one(FzHttp.Devices.Device)
      assert device.name == "big-head-007"
      assert device.description == "Dummy description"
      assert device.allowed_ips == [%Postgrex.INET{address: {127, 0, 0, 1}, netmask: nil}]
      assert device.dns == ["1.1.1.1", "2.2.2.2"]
      assert device.endpoint == "example.com:51820"
      assert device.mtu == 1400
      assert device.persistent_keepalive == 10
      assert device.ipv4 == %Postgrex.INET{address: {10, 10, 11, 1}}
      assert device.ipv6 == %Postgrex.INET{address: {64_768, 0, 0, 0, 0, 0, 30, 16_278}}
    end

    feature "allows user to add a device, download config and close the modal", %{
      session: session
    } do
      FzHttp.Config.put_config!(:allow_unprivileged_device_configuration, false)

      session
      |> visit(~p"/user_devices")
      |> assert_el(Query.text("Your Devices"))
      |> click(Query.link("Add Device"))
      |> assert_el(Query.button("Generate Configuration"))
      |> fill_form(%{
        "device[name]" => "big-hand-007",
        "device[description]" => "Dummy description"
      })
      |> fill_in(Query.fillable_field("device[description]"), with: "Dummy description")
      |> click(Query.button("Generate Configuration"))
      |> assert_el(Query.text("Device added!"))
      |> click(Query.css("#download-config"))
      |> click(Query.css("button[phx-click=\"close\"]"))
      |> assert_el(Query.text("big-hand-007"))
      |> assert_path(~p"/user_devices")

      assert device = Repo.one(FzHttp.Devices.Device)
      assert device.name == "big-hand-007"
      assert device.description == "Dummy description"
    end

    feature "does not allow adding devices", %{session: session} do
      FzHttp.Config.put_config!(:allow_unprivileged_device_management, false)

      session
      |> visit(~p"/user_devices")
      |> assert_el(Query.text("Your Devices"))
      |> refute_has(Query.link("Add Device"))
    end

    feature "allows user to delete a device", %{
      session: session,
      user: user
    } do
      device = DevicesFixtures.create_device_for_user(user)

      session =
        session
        |> visit(~p"/user_devices")
        |> assert_el(Query.text("Your Devices"))
        |> assert_el(Query.text(device.public_key))
        |> click(Query.link(device.name))
        |> assert_el(Query.text(device.description))

      accept_confirm(session, fn session ->
        click(session, Query.button("Delete Device #{device.name}"))
      end)

      assert_el(session, Query.text("No devices to show."))

      assert Repo.one(FzHttp.Devices.Device) == nil
    end
  end

  describe "profile" do
    setup tags do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session =
        tags.session
        |> visit(~p"/")
        |> Auth.authenticate(user)

      tags
      |> Map.put(:session, session)
      |> Map.put(:user, user)
    end

    feature "allows to change password", %{
      session: session,
      user: user
    } do
      session
      |> visit(~p"/user_devices")
      |> assert_el(Query.text("Your Devices"))
      |> click(Query.link("My Account"))
      |> assert_el(Query.text("Account Settings"))
      |> click(Query.link("Change Password"))
      |> assert_el(Query.text("Enter new password below."))
      |> fill_form(%{
        "user[password]" => "foo",
        "user[password_confirmation]" => ""
      })
      |> click(Query.button("Save"))
      |> assert_el(Query.text("should be at least 12 character(s)"))
      |> assert_el(Query.text("does not match confirmation"))
      |> fill_form(%{
        "user[password]" => "new_password",
        "user[password_confirmation]" => "new_password"
      })
      |> click(Query.button("Save"))
      |> assert_el(Query.text("Password updated successfully"))

      assert Repo.one(FzHttp.Users.User).password_hash != user.password_hash
    end
  end
end
