defmodule FgHttp.ReleaseTest do
  @moduledoc """
  XXX: Write more meaningful tests for this module.
  Perhaps the best way to test this module is through functional tests.
  """

  use FgHttp.DataCase, async: true

  alias FgHttp.{Release, Users, Users.User}

  describe "gen_secret/1" do
    test "calls function" do
      Release.gen_secret(32)
    end
  end

  describe "migrate/0" do
    test "calls function" do
      Release.migrate()
    end
  end

  describe "rollback/2" do
  end

  describe "create_admin_user/0" do
    test "creates user" do
      Release.create_admin_user()
      user = Users.get_user!(email: Application.fetch_env!(:fg_http, :admin_user_email))
      assert %User{} = user
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
