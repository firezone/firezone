defmodule FzHttp.UsersTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Users

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

    test "raises Ecto.NoResultsError for missing Users", %{user: _user} do
      assert_raise(Ecto.NoResultsError, fn ->
        Users.get_user!(0)
      end)
    end
  end

  describe "get_user/1" do
    setup [:create_user]

    test "returns user if found", %{user: user} do
      assert Users.get_user(user.id).id == user.id
    end

    test "returns nil if not found" do
      assert nil == Users.get_user(0)
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
    @too_short_password [
      email: "valid@test",
      password: "short11",
      password_confirmation: "short11"
    ]
    @too_long_password [
      email: "valid@test",
      password: String.duplicate("a", 65),
      password_confirmation: String.duplicate("a", 65)
    ]

    test "doesn't create user with password too short" do
      assert {:error, changeset} = Users.create_user(@too_short_password)

      assert changeset.errors[:password] == {
               "should be at least %{count} character(s)",
               [count: 8, validation: :length, kind: :min, type: :string]
             }
    end

    test "doesn't create user with password too long" do
      assert {:error, changeset} = Users.create_user(@too_long_password)

      assert changeset.errors[:password] == {
               "should be at most %{count} character(s)",
               [count: 64, validation: :length, kind: :max, type: :string]
             }
    end

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

    @change_password_valid_params %{
      "password" => "new_password",
      "password_confirmation" => "new_password",
      "current_password" => "testtest"
    }
    @change_password_invalid_params %{
      "password" => "new_password",
      "password_confirmation" => "new_password",
      "current_password" => "invalid"
    }
    @password_params %{"password" => "new_password", "password_confirmation" => "new_password"}
    @email_params %{"email" => "new_email@test"}
    @email_and_password_params %{
      "password" => "new_password",
      "password_confirmation" => "new_password",
      "email" => "new_email@test"
    }
    @no_password_params %{"password_hash" => nil}
    @empty_password_params %{
      "password" => nil,
      "password_confirmation" => nil,
      "current_password" => nil
    }
    @email_empty_password_params %{
      "email" => "foobar@test",
      "password" => "",
      "password_confirmation" => "",
      "current_password" => ""
    }
    @sign_in_token_params %{
      "sign_in_token" => "foobar",
      "sign_in_token_created_at" => DateTime.utc_now()
    }

    test "changes password when only password is updated", %{user: user} do
      {:ok, new_user} = Users.update_user(user, @password_params)
      assert new_user.password_hash != user.password_hash
    end

    test "changes password when current_password valid", %{user: user} do
      {:ok, new_user} = Users.update_user(user, @change_password_valid_params)
      assert new_user.password_hash != user.password_hash
    end

    test "does not change password when current_password invalid", %{user: user} do
      {:error, changeset} = Users.update_user(user, @change_password_invalid_params)
      assert [current_password: _] = changeset.errors
    end

    test "prevents clearing the password", %{user: user} do
      {:ok, new_user} = Users.update_user(user, @no_password_params)
      assert new_user.password_hash == user.password_hash
    end

    test "nil password params", %{user: user} do
      {:ok, new_user} = Users.update_user(user, @empty_password_params)
      assert new_user.password_hash == user.password_hash
    end

    test "adding a sign in token", %{user: user} do
      {:ok, new_user} = Users.update_user(user, @sign_in_token_params)
      assert new_user.sign_in_token == @sign_in_token_params["sign_in_token"]
    end

    test "changes email", %{user: user} do
      {:ok, new_user} = Users.update_user(user, @email_params)
      assert new_user.email == "new_email@test"
    end

    test "handles empty params", %{user: user} do
      assert {:ok, _new_user} = Users.update_user(user, %{})
    end

    test "handles nil password", %{user: user} do
      assert {:ok, _new_user} = Users.update_user(user, @email_empty_password_params)
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
