defmodule FzHttp.UsersTest do
  use FzHttp.DataCase, async: true
  alias FzHttp.UsersFixtures
  alias FzHttp.DevicesFixtures
  alias FzHttp.Users

  describe "count/0" do
    test "returns correct count of all users" do
      assert Users.count() == 0

      UsersFixtures.create_user()
      assert Users.count() == 1

      UsersFixtures.create_user()
      assert Users.count() == 2
    end
  end

  describe "count_by_role/0" do
    test "returns 0 when there are no users" do
      assert Users.count_by_role(:unprivileged) == 0
      assert Users.count_by_role(:admin) == 0
    end

    test "returns correct count of admin users" do
      UsersFixtures.create_user_with_role(:admin)
      assert Users.count_by_role(:admin) == 1
      assert Users.count_by_role(:unprivileged) == 0

      UsersFixtures.create_user_with_role(:unprivileged)
      assert Users.count_by_role(:admin) == 1
      assert Users.count_by_role(:unprivileged) == 1

      for _ <- 1..5, do: UsersFixtures.create_user_with_role(:unprivileged)
      assert Users.count_by_role(:admin) == 1
      assert Users.count_by_role(:unprivileged) == 6
    end
  end

  describe "fetch_user_by_id/1" do
    test "returns error when user is not found" do
      assert Users.fetch_user_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUIDv4" do
      assert Users.fetch_user_by_id("foo") == {:error, :not_found}
    end

    test "returns user" do
      user = UsersFixtures.create_user()
      assert {:ok, returned_user} = Users.fetch_user_by_id(user.id)
      assert returned_user.id == user.id
    end
  end

  describe "fetch_user_by_id!/1" do
    test "raises when user is not found" do
      assert_raise(Ecto.NoResultsError, fn ->
        Users.fetch_user_by_id!(Ecto.UUID.generate())
      end)
    end

    test "raises when id is not a valid UUIDv4" do
      assert_raise(Ecto.Query.CastError, fn ->
        assert Users.fetch_user_by_id!("foo")
      end)
    end

    test "returns user" do
      user = UsersFixtures.create_user()
      assert returned_user = Users.fetch_user_by_id!(user.id)
      assert returned_user.id == user.id
    end
  end

  describe "fetch_user_by_email/1" do
    test "returns error when user is not found" do
      assert Users.fetch_user_by_email("foo@bar") == {:error, :not_found}
    end

    test "returns user" do
      user = UsersFixtures.create_user()
      assert {:ok, returned_user} = Users.fetch_user_by_email(user.email)
      assert returned_user.id == user.id
    end
  end

  describe "fetch_user_by_id_or_email/1" do
    test "returns error when user is not found" do
      assert Users.fetch_user_by_id_or_email(Ecto.UUID.generate()) == {:error, :not_found}
      assert Users.fetch_user_by_id_or_email("foo@bar.com") == {:error, :not_found}
      assert Users.fetch_user_by_id_or_email("foo") == {:error, :not_found}
    end

    test "returns user by id" do
      user = UsersFixtures.create_user()
      assert {:ok, returned_user} = Users.fetch_user_by_id(user.id)
      assert returned_user.id == user.id
    end

    test "returns user by email" do
      user = UsersFixtures.create_user()
      assert {:ok, returned_user} = Users.fetch_user_by_email(user.email)
      assert returned_user.id == user.id
    end
  end

  describe "list_users/1" do
    test "returns empty list when there are not users" do
      assert Users.list_users() == []
      assert Users.list_users(hydrate: [:device_count]) == []
    end

    test "returns list of users in all roles" do
      user1 = UsersFixtures.create_user_with_role(:admin)
      user2 = UsersFixtures.create_user_with_role(:unprivileged)

      assert users = Users.list_users()
      assert length(users) == 2
      assert Enum.sort(Enum.map(users, & &1.id)) == Enum.sort([user1.id, user2.id])
    end

    test "hydrates users with device count" do
      user1 = UsersFixtures.create_user_with_role(:admin)
      DevicesFixtures.create_device_for_user(user1)

      user2 = UsersFixtures.create_user_with_role(:unprivileged)
      DevicesFixtures.create_device_for_user(user2)
      DevicesFixtures.create_device_for_user(user2)

      assert users = Users.list_users(hydrate: [:device_count])
      assert length(users) == 2

      assert Enum.sort(Enum.map(users, &{&1.id, &1.device_count})) ==
               Enum.sort([{user1.id, 1}, {user2.id, 2}])

      assert users = Users.list_users(hydrate: [:device_count, :device_count])

      assert Enum.sort(Enum.map(users, &{&1.id, &1.device_count})) ==
               Enum.sort([{user1.id, 1}, {user2.id, 2}])
    end
  end

  describe "request_sign_in_token/1" do
    test "returns user with updated sign-in token" do
      user = UsersFixtures.create_user()
      refute user.sign_in_token_hash

      assert {:ok, user} = Users.request_sign_in_token(user)
      assert user.sign_in_token
      assert user.sign_in_token_hash
      assert user.sign_in_token_created_at
    end
  end

  describe "consume_sign_in_token/1" do
    test "returns user when token is valid" do
      {:ok, user} =
        UsersFixtures.create_user()
        |> Users.request_sign_in_token()

      assert {:ok, signed_in_user} = Users.consume_sign_in_token(user, user.sign_in_token)
      assert signed_in_user.id == user.id
    end

    test "clears the sign in token when consumed" do
      {:ok, user} =
        UsersFixtures.create_user()
        |> Users.request_sign_in_token()

      assert {:ok, user} = Users.consume_sign_in_token(user, user.sign_in_token)
      assert is_nil(user.sign_in_token)
      assert is_nil(user.sign_in_token_created_at)

      assert user = Repo.one(Users.User)
      assert is_nil(user.sign_in_token)
      assert is_nil(user.sign_in_token_created_at)
    end

    test "returns error when token doesn't exist" do
      user = UsersFixtures.create_user()

      assert Users.consume_sign_in_token(user, "foo") == {:error, :no_token}
    end

    test "token expires in one hour" do
      about_one_hour_ago =
        DateTime.utc_now()
        |> DateTime.add(-1, :hour)
        |> DateTime.add(30, :second)

      {:ok, user} =
        UsersFixtures.create_user()
        |> Users.request_sign_in_token()

      user
      |> Ecto.Changeset.change(sign_in_token_created_at: about_one_hour_ago)
      |> Repo.update!()

      assert {:ok, _user} = Users.consume_sign_in_token(user, user.sign_in_token)
    end

    test "returns error when token is expired" do
      one_hour_and_one_second_ago =
        DateTime.utc_now()
        |> DateTime.add(-1, :hour)
        |> DateTime.add(-1, :second)

      {:ok, user} =
        UsersFixtures.create_user()
        |> Users.request_sign_in_token()

      user =
        user
        |> Ecto.Changeset.change(sign_in_token_created_at: one_hour_and_one_second_ago)
        |> Repo.update!()

      assert Users.consume_sign_in_token(user, user.sign_in_token) == {:error, :token_expired}
    end
  end

  ####

  describe "create_user/1" do
    test "returns changeset error when attrs are missing" do
      assert {:error, changeset} = Users.create_user(%{})

      refute changeset.valid?
      assert length(changeset.errors) == 1

      assert "can't be blank" in errors_on(changeset).email
    end

    @valid_attrs_map %{
      email: "valid@test",
      password: "password1234",
      password_confirmation: "password1234"
    }
    @valid_attrs_list [
      email: "valid@test",
      password: "password1234",
      password_confirmation: "password1234"
    ]
    @invalid_attrs_map %{
      email: "invalid_email",
      password: "password1234",
      password_confirmation: "password1234"
    }
    @invalid_attrs_list [
      email: "valid@test",
      password: "password1234",
      password_confirmation: "different_password1234"
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
      assert {:error, changeset} = Users.create_admin_user(@too_short_password)

      assert changeset.errors[:password] == {
               "should be at least %{count} character(s)",
               [count: 12, validation: :length, kind: :min, type: :string]
             }
    end

    test "doesn't create user with password too long" do
      assert {:error, changeset} = Users.create_admin_user(@too_long_password)

      assert changeset.errors[:password] == {
               "should be at most %{count} character(s)",
               [count: 64, validation: :length, kind: :max, type: :string]
             }
    end

    test "creates user with valid map of attributes" do
      assert {:ok, _user} = Users.create_admin_user(@valid_attrs_map)
    end

    test "creates user with valid list of attributes" do
      assert {:ok, _user} = Users.create_admin_user(@valid_attrs_list)
    end

    test "doesn't create user with invalid map of attributes" do
      assert {:error, _changeset} = Users.create_admin_user(@invalid_attrs_map)
    end

    test "doesn't create user with invalid list of attributes" do
      assert {:error, _changeset} = Users.create_admin_user(@invalid_attrs_list)
    end
  end

  ####

  describe "trimmed fields" do
    test "trims expected fields" do
      changeset =
        Users.User.Changeset.create_changeset(%{
          "email" => " foo "
        })

      assert %Ecto.Changeset{
               changes: %{
                 email: "foo"
               }
             } = changeset
    end
  end

  @change_password_valid_params %{
    password: "new_password",
    password_confirmation: "new_password",
    current_password: "password1234"
  }
  @change_password_invalid_params %{
    "password" => "new_password",
    "password_confirmation" => "new_password",
    "current_password" => "invalid"
  }
  @password_params %{"password" => "new_password", "password_confirmation" => "new_password"}
  @email_params %{"email" => "new_email@test", "current_password" => "password1234"}
  @email_and_password_params %{
    "password" => "new_password",
    "password_confirmation" => "new_password",
    "email" => "new_email@test",
    "current_password" => "password1234"
  }
  @clear_hash_params %{"password_hash" => nil, "current_password" => "password1234"}
  @empty_password_params %{
    "password" => nil,
    "password_confirmation" => nil,
    "current_password" => "password1234"
  }
  @email_empty_password_params %{
    "email" => "foobar@test",
    "password" => "",
    "password_confirmation" => "",
    "current_password" => "password1234"
  }

  describe "admin_update_user/2" do
    setup :create_user

    test "changes password", %{user: user} do
      {:ok, new_user} = Users.admin_update_user(user, @password_params)
      assert new_user.password_hash != user.password_hash
    end

    test "prevents clearing the password", %{user: user} do
      {:ok, new_user} = Users.admin_update_user(user, @clear_hash_params)
      assert new_user.password_hash == user.password_hash
    end

    test "nil password params", %{user: user} do
      {:ok, new_user} = Users.admin_update_user(user, @empty_password_params)
      assert new_user.password_hash == user.password_hash
    end

    test "changes email", %{user: user} do
      {:ok, new_user} = Users.admin_update_user(user, @email_params)
      assert new_user.email == "new_email@test"
    end

    test "handles empty params", %{user: user} do
      assert {:ok, _new_user} = Users.admin_update_user(user, %{})
    end

    test "handles nil password", %{user: user} do
      assert {:ok, _new_user} = Users.admin_update_user(user, @email_empty_password_params)
    end

    test "changes email and password", %{user: user} do
      {:ok, new_user} = Users.admin_update_user(user, @email_and_password_params)
      assert new_user.email == "new_email@test"
      assert new_user.password_hash != user.password_hash
    end
  end

  describe "unprivileged_update_self/2" do
    setup :create_user

    test "changes password", %{user: user} do
      {:ok, new_user} = Users.unprivileged_update_self(user, @password_params)
      assert new_user.password_hash != user.password_hash
    end

    test "prevents clearing the password", %{user: user} do
      assert {:error, _changeset} = Users.unprivileged_update_self(user, @clear_hash_params)
    end

    test "prevents changing email", %{user: user} do
      {:ok, new_user} = Users.unprivileged_update_self(user, @email_and_password_params)
      assert new_user.email == user.email
    end
  end

  describe "admin_update_self/2" do
    setup :create_user

    test "does not change password when current_password invalid", %{user: user} do
      {:error, changeset} = Users.admin_update_self(user, @change_password_invalid_params)
      assert [current_password: _] = changeset.errors
    end

    test "changes password when current_password valid", %{user: user} do
      {:ok, new_user} = Users.admin_update_self(user, @change_password_valid_params)
      assert new_user.password_hash != user.password_hash
    end
  end

  describe "update_*" do
    setup :create_user

    test "update role", %{user: user} do
      {:ok, user} = Users.update_user_role(user, :admin)
      assert user.role == :admin

      {:ok, user} = Users.update_user_role(user, :unprivileged)
      assert user.role == :unprivileged
    end

    test "update last_signed_in_*", %{user: user} do
      {:ok, user} = Users.update_last_signed_in(user, %{provider: :test})
      assert user.last_signed_in_method == "test"

      {:ok, user} = Users.update_last_signed_in(user, %{provider: :another_test})
      assert user.last_signed_in_method == "another_test"
    end
  end

  describe "delete_user/1" do
    setup :create_user

    test "raises Ecto.NoResultsError when a deleted user is fetched", %{user: user} do
      Users.delete_user(user)

      assert_raise(Ecto.NoResultsError, fn ->
        Users.fetch_user_by_id!(user.id)
      end)
    end
  end

  describe "change_user/1" do
    setup :create_user

    test "returns changeset", %{user: user} do
      assert %Ecto.Changeset{} = Users.change_user(user)
    end
  end

  describe "setting_projection/1" do
    setup [:create_rule_with_user_and_device]

    test "projects expected fields with user", %{user: user} do
      assert user.id == Users.setting_projection(user)
    end

    test "projects expected fields with user map", %{user: user} do
      user_map = Map.from_struct(user)
      assert user.id == Users.setting_projection(user_map)
    end
  end

  describe "as_settings/0" do
    setup [:create_rules]

    test "Maps rules to projections", %{users: users} do
      expected_users = Enum.map(users, &Users.setting_projection/1) |> MapSet.new()

      assert Users.as_settings() == expected_users
    end
  end
end
