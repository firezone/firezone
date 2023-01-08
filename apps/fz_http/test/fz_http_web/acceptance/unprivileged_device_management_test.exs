defmodule FzHttpWeb.Acceptance.UnprivilegedDeviceManagementTest do
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
        |> assert_has(Query.text("Your Devices"))
        |> click(Query.link("Add Device"))
        |> fill_in(Query.fillable_field("device[description]"), with: "Dummy description")
        |> click(Query.button("Generate Configuration"))
        |> assert_has(Query.text("Device added!"))
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
        |> assert_has(Query.text("Your Devices"))
        |> assert_has(Query.text(device.public_key))
        |> click(Query.link(device.name))
        |> assert_has(Query.text(device.description))

      accept_confirm(session, fn session ->
        click(session, Query.button("Delete Device #{device.name}"))
      end)

      assert_has(session, Query.text("No devices to show."))

      assert Repo.one(FzHttp.Devices.Device) == nil
    end

    feature "allows unprivileged user to change password", %{
      session: session
    } do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session
      |> visit(~p"/")
      |> Auth.authenticate(user)
      |> visit(~p"/user_devices")
      |> assert_has(Query.text("Your Devices"))
      |> click(Query.link("My Account"))
      |> assert_has(Query.text("Account Settings"))
      |> click(Query.link("Change Password"))
      |> assert_has(Query.text("Enter new password below."))
      |> fill_in(Query.fillable_field("user[password]"), with: "foo")
      |> fill_in(Query.fillable_field("user[password_confirmation]"), with: "")
      |> click(Query.button("Save"))
      |> assert_has(Query.text("should be at least 12 character(s)"))
      |> assert_has(Query.text("does not match confirmation"))
      |> fill_in(Query.fillable_field("user[password]"), with: "new_password")
      |> fill_in(Query.fillable_field("user[password_confirmation]"), with: "new_password")
      |> click(Query.button("Save"))
      |> assert_has(Query.text("Password updated successfully"))

      assert Repo.one(FzHttp.Users.User).password_hash != user.password_hash
    end

    feature "allows unprivileged user to add MFA method", %{
      session: session
    } do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      session
      |> visit(~p"/")
      |> Auth.authenticate(user)
      |> visit(~p"/user_devices")
      |> assert_has(Query.text("Your Devices"))
      |> click(Query.link("My Account"))
      |> assert_has(Query.text("Account Settings"))
      |> click(Query.link("Add MFA Method"))
      |> mfa_flow()
    end

    feature "allows admin user to add MFA method", %{
      session: session
    } do
      user = UsersFixtures.create_user_with_role(:admin)

      session
      |> visit(~p"/")
      |> Auth.authenticate(user)
      |> visit(~p"/users")
      |> hover(Query.css(".is-user-name span"))
      |> click(Query.link("Account Settings"))
      |> assert_has(Query.text("Multi Factor Authentication"))
      |> click(Query.link("Add MFA Method"))
      |> mfa_flow()
    end
  end

  defp mfa_flow(session) do
    assert selected?(session, Query.radio_button("mfa-method-totp"))

    session =
      session
      |> click(Query.button("Next"))
      |> assert_has(Query.text("Register Authenticator"))
      |> fill_in(Query.fillable_field("name"), with: "My MFA Name")

    secret =
      Browser.text(session, Query.css("#copy-totp-key"))
      |> String.replace(" ", "")
      |> Base.decode32!()

    session
    |> click(Query.button("Next"))
    |> assert_has(Query.text("Verify Code"))
    |> fill_in(Query.fillable_field("code"), with: "123456")
    |> click(Query.button("Next"))
    |> assert_has(Query.css("input.is-danger"))
    |> fill_in(Query.fillable_field("code"), with: NimbleTOTP.verification_code(secret))
    |> click(Query.button("Next"))
    |> assert_has(Query.text("Confirm to save this Authentication method."))
    |> click(Query.button("Save"))
    |> assert_has(Query.text("MFA method added!"))

    assert mfa_method = Repo.one(FzHttp.MFA.Method)
    assert mfa_method.name == "My MFA Name"
    assert mfa_method.payload["secret"] == Base.encode64(secret)
  end
end
