defmodule FgHttp.UsersTest do
  use FgHttp.DataCase, async: true

  alias FgHttp.Users

  describe "consume_sign_in_token/1" do
  end

  describe "get_user!/1" do
  end

  describe "create_user/1" do
  end

  describe "sign_in_keys/0" do
  end

  describe "update_user/2" do
    setup [:create_user]

    test "changes password", %{user: user} do
      params = %{"password" => "new_password", "password_confirmation" => "new_password"}
      {:ok, new_user} = Users.update_user(user, params)

      assert new_user.password_hash != user.password_hash
    end
  end

  describe "delete_user/1" do
  end

  describe "change_user/1" do
  end

  describe "new_user/0" do
  end

  describe "single_user?/0" do
  end

  describe "admin/0" do
  end

  describe "admin_email/0" do
  end
end
