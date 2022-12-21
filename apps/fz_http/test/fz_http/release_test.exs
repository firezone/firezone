defmodule FzHttp.ReleaseTest do
  @moduledoc """
  XXX: Write more meaningful tests for this module.
  Perhaps the best way to test this module is through functional tests.
  """

  use FzHttp.DataCase, async: true

  alias FzHttp.{Release, Users, Users.User}

  describe "migrate/0" do
    test "function runs without error" do
      assert Release.migrate()
    end
  end

  describe "rollback/2" do
    test "calls function" do
      for repo <- Release.repos() do
        assert Release.rollback(repo, 0)
      end
    end
  end

  describe "create_admin_user/0" do
    test "creates admin when none exists" do
      Release.create_admin_user()
      user = Users.get_user!(email: Application.fetch_env!(:fz_http, :admin_email))
      assert %User{} = user
    end

    test "reset admin password when user exists" do
      {:ok, first_user} = Release.create_admin_user()
      {:ok, new_first_user} = Release.change_password(first_user.email, "newpassword1234")
      {:ok, second_user} = Release.create_admin_user()

      assert second_user.password_hash != new_first_user.password_hash
    end
  end

  describe "change_password/2" do
    setup [:create_user]

    test "changes password", %{user: user} do
      Release.change_password(user.email, "this password should be different")
      new_user = Users.get_user!(email: user.email)

      assert new_user.password_hash != user.password_hash
    end
  end
end
