defmodule FzHttpWeb.Acceptance.UnprivilegedUserTest do
  use FzHttpWeb.AcceptanceCase, async: true
  alias FzHttp.{UsersFixtures, DevicesFixtures}

  describe "device management" do
    feature "allows user to add a device", %{
      session: session
    } do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session =
        session
        |> visit(~p"/")
        |> Auth.authenticate(user)
        |> visit(~p"/user_devices")
        |> assert_el(Query.text("Your Devices"))
        |> click(Query.link("Add Device"))
        |> assert_el(Query.button("Generate Configuration"))
        |> fill_in(Query.fillable_field("device[description]"), with: "Dummy description")
        |> click(Query.button("Generate Configuration"))
        |> assert_el(Query.text("Device added!"))
    end

    feature "allows user to delete a device", %{
      session: session
    } do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      device = DevicesFixtures.create_device_for_user(user)

      session =
        session
        |> visit(~p"/")
        |> Auth.authenticate(user)
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
    feature "allows to change password", %{
      session: session
    } do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session =
        session
        |> visit(~p"/")
        |> Auth.authenticate(user)
        |> visit(~p"/user_devices")
        |> assert_el(Query.text("Your Devices"))
        |> click(Query.link("My Account"))
        |> assert_el(Query.text("Account Settings"))
        |> click(Query.link("Change Password"))
        # TODO: abstract form helper out: take a submit button and fields,
        # then always assert form is visible, that we know all elements of it,
        # and than submit button is visible before we fill it out
        |> assert_el(Query.text("Enter new password below."))
        |> fill_in(Query.fillable_field("user[password]"), with: "foo")
        |> fill_in(Query.fillable_field("user[password_confirmation]"), with: "")
        |> click(Query.button("Save"))
        |> assert_el(Query.text("should be at least 12 character(s)"))
        |> assert_el(Query.text("does not match confirmation"))

      # Make sure form only contains two inputs
      find(session, Query.css(".input", count: 2))

      session
      |> fill_in(Query.fillable_field("user[password]"), with: "new_password")
      |> fill_in(Query.fillable_field("user[password_confirmation]"), with: "new_password")
      |> click(Query.button("Save"))
      |> assert_el(Query.text("Password updated successfully"))

      assert Repo.one(FzHttp.Users.User).password_hash != user.password_hash
    end
  end
end
