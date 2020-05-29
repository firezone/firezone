defmodule FgHttp.PasswordResetsTest do
  use FgHttp.DataCase

  alias FgHttp.{Fixtures, PasswordResets}

  describe "password_resets" do
    alias FgHttp.Users.PasswordReset

    @valid_attrs %{reset_sent_at: "2010-04-17T14:00:00Z"}
    @update_attrs %{reset_sent_at: "2011-05-18T15:01:01Z"}
    @invalid_attrs %{reset_sent_at: nil}

    def password_reset_fixture(attrs \\ %{}) do
      {:ok, password_reset} =
        attrs
        |> Enum.into(%{user_id: Fixtures.user().id})
        |> Enum.into(@valid_attrs)
        |> PasswordResets.create_password_reset()

      password_reset
    end

    test "list_password_resets/0 returns all password_resets" do
      password_reset = password_reset_fixture()
      assert PasswordResets.list_password_resets() == [password_reset]
    end

    test "get_password_reset!/1 returns the password_reset with given id" do
      password_reset = password_reset_fixture()
      assert PasswordResets.get_password_reset!(password_reset.id) == password_reset
    end

    test "create_password_reset/1 with valid data creates a password_reset" do
      user_id = Fixtures.user().id
      valid_attrs = Map.merge(@valid_attrs, %{user_id: user_id})

      assert {:ok, %PasswordReset{} = password_reset} =
               PasswordResets.create_password_reset(valid_attrs)

      assert password_reset.reset_sent_at ==
               DateTime.from_naive!(~N[2010-04-17T14:00:00Z], "Etc/UTC")

      assert password_reset.reset_token
      assert password_reset.user_id == user_id
    end

    test "create_password_reset/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = PasswordResets.create_password_reset(@invalid_attrs)
    end

    test "update_password_reset/2 with valid data updates the password_reset" do
      password_reset = password_reset_fixture()

      assert {:ok, %PasswordReset{} = password_reset} =
               PasswordResets.update_password_reset(password_reset, @update_attrs)

      assert password_reset.reset_sent_at ==
               DateTime.from_naive!(~N[2011-05-18T15:01:01Z], "Etc/UTC")

      assert password_reset.reset_token
    end

    test "update_password_reset/2 with invalid data returns error changeset" do
      invalid_attrs = Map.merge(@invalid_attrs, %{reset_token: nil})
      password_reset = password_reset_fixture()

      assert {:error, %Ecto.Changeset{}} =
               PasswordResets.update_password_reset(password_reset, invalid_attrs)

      assert password_reset == PasswordResets.get_password_reset!(password_reset.id)
    end

    test "delete_password_reset/1 deletes the password_reset" do
      password_reset = password_reset_fixture()
      assert {:ok, %PasswordReset{}} = PasswordResets.delete_password_reset(password_reset)

      assert_raise Ecto.NoResultsError, fn ->
        PasswordResets.get_password_reset!(password_reset.id)
      end
    end

    test "change_password_reset/1 returns a password_reset changeset" do
      password_reset = password_reset_fixture()
      assert %Ecto.Changeset{} = PasswordResets.change_password_reset(password_reset)
    end
  end
end
