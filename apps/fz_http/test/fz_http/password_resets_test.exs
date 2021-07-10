defmodule FzHttp.PasswordResetsTest do
  use FzHttp.DataCase, async: true
  alias FzHttp.{PasswordResets, Users}

  describe "get_password_reset!/1 non-expired token" do
    setup [:create_password_reset]

    test "valid token", %{password_reset: password_reset} do
      test_password_reset =
        PasswordResets.get_password_reset!(reset_token: password_reset.reset_token)

      assert test_password_reset.id == password_reset.id
    end

    test "invalid token", %{password_reset: _password_reset} do
      assert_raise(Ecto.NoResultsError, fn ->
        PasswordResets.get_password_reset!(reset_token: "invalid")
      end)
    end

    test "valid email", %{password_reset: password_reset} do
      test_password_reset = PasswordResets.get_password_reset!(email: password_reset.email)
      assert test_password_reset.id == password_reset.id
    end

    test "invalid email", %{password_reset: _password_reset} do
      assert_raise(Ecto.NoResultsError, fn ->
        PasswordResets.get_password_reset!(email: "invalid")
      end)
    end
  end

  describe "get_password_reset!/1 expired token" do
    setup [:expired_reset_token]

    test "expired token", %{expired_reset_token: expired_reset_token} do
      assert_raise(Ecto.NoResultsError, fn ->
        PasswordResets.get_password_reset!(reset_token: expired_reset_token)
      end)
    end
  end

  describe "create_password_reset/2" do
    setup [:create_user]

    test "creates password_reset for valid email", %{user: user} do
      attrs = %{email: user.email}

      {:ok, password_reset} =
        PasswordResets.get_password_reset!(email: user.email)
        |> PasswordResets.create_password_reset(attrs)

      assert !is_nil(password_reset.reset_token)
      assert is_binary(password_reset.reset_token)
      assert String.length(password_reset.reset_token) == 12
    end

    test "doesn't create password_reset when email doesn't exist", %{user: user} do
      {:ok, new_pwr} =
        PasswordResets.get_password_reset!(email: user.email)
        |> PasswordResets.create_password_reset(%{email: "invalid@test"})

      assert new_pwr.email != "invalid@test"
    end

    test "doesn't create password_reset when user is deleted", %{user: user} do
      password_reset = PasswordResets.get_password_reset!(email: user.email)
      user = Users.get_user!(user.id)
      Users.delete_user(user)

      assert_raise(Ecto.StaleEntryError, fn ->
        PasswordResets.create_password_reset(password_reset, %{email: user.email})
      end)
    end
  end

  describe "update_password_reset/2" do
    setup [:create_password_reset]

    @update_attrs %{
      password: "new-password",
      password_confirmation: "new-password"
    }

    test "clears reset_token", %{password_reset: password_reset} do
      assert is_binary(password_reset.reset_token)
      assert String.length(password_reset.reset_token) > 0

      {:ok, test_password_reset} =
        PasswordResets.update_password_reset(password_reset, @update_attrs)

      assert is_nil(test_password_reset.reset_token)
    end
  end

  describe "new_password_reset/0" do
    test "returns changeset" do
      assert %Ecto.Changeset{} = PasswordResets.new_password_reset()
    end
  end

  describe "edit_password_reset/1" do
    setup [:create_password_reset]

    test "returns changeset", %{password_reset: password_reset} do
      assert %Ecto.Changeset{} = PasswordResets.edit_password_reset(password_reset)
    end
  end
end
