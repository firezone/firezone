defmodule FgHttp.PasswordResetsTest do
  use FgHttp.DataCase

  alias FgHttp.{Fixtures, PasswordResets}

  describe "password_resets" do
    alias FgHttp.Users.PasswordReset

    @valid_attrs %{email: "test@test"}
    @invalid_attrs %{email: "invalid"}

    test "get_password_reset!/1 returns the password_reset with given token" do
      token = Fixtures.password_reset(%{reset_sent_at: DateTime.utc_now()}).reset_token
      gotten = PasswordResets.get_password_reset!(reset_token: token)
      assert gotten.reset_token == token
    end

    test "create_password_reset/1 with valid data creates a password_reset" do
      email = Fixtures.user().email

      assert {:ok, %PasswordReset{} = password_reset} =
               PasswordResets.create_password_reset(Fixtures.password_reset(), @valid_attrs)

      # reset_sent_at should be nil after creation
      assert !is_nil(password_reset.reset_sent_at)

      assert password_reset.reset_token
      assert password_reset.email == email
    end

    test "create_password_reset/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} =
               PasswordResets.create_password_reset(
                 Fixtures.password_reset(),
                 @invalid_attrs
               )
    end
  end
end
