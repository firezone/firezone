defmodule Domain.ReleaseTest do
  @moduledoc """
  XXX: Write more meaningful tests for this module.
  Perhaps the best way to test this module is through functional tests.
  """
  use Domain.DataCase, async: true
  alias Domain.{ApiTokens, Users}
  alias Domain.Release
  alias Domain.UsersFixtures

  describe "migrate/0" do
    test "function runs without error" do
      assert Release.migrate()
    end
  end

  describe "create_admin_user/0" do
    test "creates admin when none exists" do
      Release.create_admin_user()
      email = Domain.Config.fetch_env!(:domain, :admin_email)
      assert {:ok, %Users.User{}} = Users.fetch_user_by_email(email)
    end

    test "reset admin password when user exists" do
      {:ok, first_user} = Release.create_admin_user()
      {:ok, new_first_user} = Release.change_password(first_user.email, "newpassword1234")
      {:ok, second_user} = Release.create_admin_user()

      assert second_user.password_hash != new_first_user.password_hash
    end
  end

  describe "create_api_token/1" do
    test "creates api_token_token for default admin user" do
      admin_user =
        UsersFixtures.create_user_with_role(:admin, %{
          email: Domain.Config.fetch_env!(:domain, :admin_email)
        })

      assert :ok = Release.create_api_token()
      assert ApiTokens.count_by_user_id(admin_user.id) == 1
    end
  end

  describe "change_password/2" do
    test "changes password" do
      user = UsersFixtures.create_user_with_role(:unprivileged)

      Release.change_password(user.email, "this password should be different")
      assert {:ok, new_user} = Users.fetch_user_by_email(user.email)

      assert new_user.password_hash != user.password_hash
    end
  end
end
