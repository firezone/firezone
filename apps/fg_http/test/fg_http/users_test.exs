defmodule FgHttp.UsersTest do
  use FgHttp.DataCase, async: true

  alias FgHttp.Users

  describe "consume_sign_in_token/1 valid token" do
    setup [:create_user_with_valid_sign_in_token]

    test "returns user when token is valid", %{user: user} do
      {:ok, signed_in_user} = Users.consume_sign_in_token(user.sign_in_token)

      assert signed_in_user.id == user.id
    end

    test "clears the sign in token when consumed", %{user: user} do
      Users.consume_sign_in_token(user.sign_in_token)

      assert is_nil(Users.get_user!(user.id).sign_in_token)
      assert is_nil(Users.get_user!(user.id).sign_in_token_created_at)
    end
  end

  describe "consume_sign_in_token/1 invalid token" do
    setup [:create_user_with_expired_sign_in_token]

    test "returns {:error, msg} when token doesn't exist", %{user: _user} do
      assert {:error, "Token invalid."} = Users.consume_sign_in_token("blah")
    end

    test "returns {:error, msg} when token is expired", %{user: user} do
      assert {:error, "Token invalid."} = Users.consume_sign_in_token(user.sign_in_token)
    end
  end

  describe "get_user!/1" do
    setup [:create_user]

    test "gets user by id", %{user: user} do
      assert Users.get_user!(user.id).id == user.id
    end
  end

  describe "create_user/1" do
    @valid_attrs_map %{
      email: "valid@test",
      password: "password",
      password_confirmation: "password"
    }
    @valid_attrs_list [
      email: "valid@test",
      password: "password",
      password_confirmation: "password"
    ]
    @invalid_attrs_map %{
      email: "invalid_email",
      password: "password",
      password_confirmation: "password"
    }
    @invalid_attrs_list [
      email: "valid@test",
      password: "password",
      password_confirmation: "different_password"
    ]

    test "creates user with valid map of attributes" do
      assert {:ok, _user} = Users.create_user(@valid_attrs_map)
    end

    test "creates user with valid list of attributes" do
      assert {:ok, _user} = Users.create_user(@valid_attrs_list)
    end

    test "doesn't create user with invalid map of attributes" do
      assert {:error, _changeset} = Users.create_user(@invalid_attrs_map)
    end

    test "doesn't create user with invalid list of attributes" do
      assert {:error, _changeset} = Users.create_user(@invalid_attrs_list)
    end
  end

  describe "sign_in_keys/0" do
    test "generates sign in token and created at" do
      params = Users.sign_in_keys()

      assert is_binary(params.sign_in_token)
      assert %DateTime{} = params.sign_in_token_created_at
    end
  end

  describe "update_user/2" do
    setup [:create_user]

    @password_params %{"password" => "new_password", "password_confirmation" => "new_password"}
    @email_params %{"email" => "new_email@test"}
    @email_and_password_params %{
      "password" => "new_password",
      "password_confirmation" => "new_password",
      "email" => "new_email@test"
    }

    test "changes password", %{user: user} do
      {:ok, new_user} = Users.update_user(user, @password_params)

      assert new_user.password_hash != user.password_hash
    end

    test "changes email", %{user: user} do
      {:ok, new_user} = Users.update_user(user, @email_params)
      assert new_user.email == "new_email@test"
    end

    test "changes email and password", %{user: user} do
      {:ok, new_user} = Users.update_user(user, @email_and_password_params)
      assert new_user.email == "new_email@test"
      assert new_user.password_hash != user.password_hash
    end
  end

  describe "delete_user/1" do
    setup [:create_user]

    test "raises Ecto.NoResultsError when a deleted user is fetched", %{user: user} do
      Users.delete_user(user)

      assert_raise(Ecto.NoResultsError, fn ->
        Users.get_user!(user.id)
      end)
    end
  end

  describe "change_user/1" do
    setup [:create_user]

    test "returns changeset", %{user: user} do
      assert %Ecto.Changeset{} = Users.change_user(user)
    end
  end

  describe "new_user/0" do
    test "returns changeset" do
      assert %Ecto.Changeset{} = Users.new_user()
    end
  end

  describe "single_user?/0 one user exists" do
    setup [:create_user]

    test "returns true", %{user: _user} do
      assert Users.single_user?()
    end
  end

  describe "single_user?/0 no users exist" do
    test "returns false" do
      assert !Users.single_user?()
    end
  end

  describe "single_user?/0 more than one user exists" do
    setup [:create_users]

    test "returns false", %{users: _users} do
      assert !Users.single_user?()
    end
  end

  describe "admin/0" do
    setup [:create_user]

    test "returns the admin user", %{user: user} do
      assert Users.admin().id == user.id
    end
  end

  describe "admin_email/0" do
    setup [:create_user]

    test "returns email of the admin", %{user: user} do
      assert Users.admin_email() == user.email
    end
  end
end
