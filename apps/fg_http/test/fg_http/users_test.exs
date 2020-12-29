defmodule FgHttp.UsersTest do
  use FgHttp.DataCase

  alias FgHttp.Users
  alias FgHttp.Users.User

  describe "users" do
    @valid_user [
      email: "admin@fireguard.dev",
      password: "test-password",
      password_confirmation: "test-password"
    ]

    test "create_user" do
      assert {:ok, %User{} = _user} = Users.create_user(@valid_user)
    end
  end
end
