defmodule FzHttp.UsersTest do
  use FzHttp.DataCase, async: true
  alias FzHttp.UsersFixtures
  alias FzHttp.DevicesFixtures
  alias FzHttp.Config
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

    test "email is not case sensitive" do
      user = UsersFixtures.create_user()
      assert {:ok, user} = Users.fetch_user_by_email(String.upcase(user.email))
      assert {:ok, ^user} = Users.fetch_user_by_email(String.downcase(user.email))
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
      assert Users.list_users() == {:ok, []}
      assert Users.list_users(hydrate: [:device_count]) == {:ok, []}
    end

    test "returns list of users in all roles" do
      user1 = UsersFixtures.create_user_with_role(:admin)
      user2 = UsersFixtures.create_user_with_role(:unprivileged)

      assert {:ok, users} = Users.list_users()
      assert length(users) == 2
      assert Enum.sort(Enum.map(users, & &1.id)) == Enum.sort([user1.id, user2.id])
    end

    test "hydrates users with device count" do
      user1 = UsersFixtures.create_user_with_role(:admin)
      DevicesFixtures.create_device_for_user(user1)

      user2 = UsersFixtures.create_user_with_role(:unprivileged)
      DevicesFixtures.create_device_for_user(user2)
      DevicesFixtures.create_device_for_user(user2)

      assert {:ok, users} = Users.list_users(hydrate: [:device_count])
      assert length(users) == 2

      assert Enum.sort(Enum.map(users, &{&1.id, &1.device_count})) ==
               Enum.sort([{user1.id, 1}, {user2.id, 2}])

      assert {:ok, users} = Users.list_users(hydrate: [:device_count, :device_count])

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

  describe "create_user/2" do
    test "returns changeset error when required attrs are missing" do
      assert {:error, changeset} = Users.create_user(%{})
      refute changeset.valid?

      assert errors_on(changeset) == %{email: ["can't be blank"]}
    end

    test "returns error on invalid attrs" do
      assert {:error, changeset} = Users.create_user(%{email: "invalid_email", password: "short"})
      refute changeset.valid?

      assert errors_on(changeset) == %{
               email: ["is invalid email address"],
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["can't be blank"]
             }

      assert {:error, changeset} =
               Users.create_user(%{email: "invalid_email", password: String.duplicate("A", 65)})

      refute changeset.valid?
      assert "should be at most 64 character(s)" in errors_on(changeset).password

      assert {:error, changeset} = Users.create_user(%{email: String.duplicate(" ", 18)})
      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset).email
    end

    test "requires password confirmation to match the password" do
      assert {:error, changeset} =
               Users.create_user(%{password: "foo", password_confirmation: "bar"})

      assert "does not match confirmation" in errors_on(changeset).password_confirmation

      assert {:error, changeset} =
               Users.create_user(%{
                 password: "password1234",
                 password_confirmation: "password1234"
               })

      refute Map.has_key?(errors_on(changeset), :password_confirmation)
    end

    test "returns error when email is already taken" do
      attrs = UsersFixtures.user_attrs()
      assert {:ok, _user} = Users.create_user(attrs)
      assert {:error, changeset} = Users.create_user(attrs)
      refute changeset.valid?
      assert "has already been taken" in errors_on(changeset).email
    end

    test "returns error when role is invalid" do
      attrs = UsersFixtures.user_attrs()

      assert_raise Ecto.ChangeError, fn ->
        Users.create_user(attrs, :foo)
      end
    end

    test "creates a user in given role" do
      for role <- [:admin, :unprivileged] do
        attrs = UsersFixtures.user_attrs()
        assert {:ok, user} = Users.create_user(attrs, role)
        assert user.role == role
      end
    end

    test "creates an unprivileged user" do
      attrs = UsersFixtures.user_attrs()
      assert {:ok, user} = Users.create_user(attrs)
      assert user.role == :unprivileged
      assert user.email == attrs.email

      assert FzCommon.FzCrypto.equal?(attrs.password, user.password_hash)
      assert is_nil(user.password)
      assert is_nil(user.password_confirmation)

      assert is_nil(user.last_signed_in_at)
      assert is_nil(user.last_signed_in_method)
      assert is_nil(user.sign_in_token)
      assert is_nil(user.sign_in_token_hash)
      assert is_nil(user.sign_in_token_created_at)
    end

    test "allows creating a user without password" do
      email = UsersFixtures.user_attrs().email
      attrs = %{email: email, password: nil, password_confirmation: nil}
      assert {:ok, user} = Users.create_user(attrs)
      assert is_nil(user.password_hash)

      email = UsersFixtures.user_attrs().email
      attrs = %{email: email, password: "", password_confirmation: ""}
      assert {:ok, user} = Users.create_user(attrs)
      assert is_nil(user.password_hash)
    end

    test "trims email" do
      attrs = UsersFixtures.user_attrs()
      updated_attrs = Map.put(attrs, :email, " #{attrs.email} ")

      assert {:ok, user} = Users.create_user(updated_attrs)

      assert user.email == attrs.email
    end
  end

  describe "admin_update_user/2" do
    test "returns ok on empty attrs" do
      user = UsersFixtures.create_user()
      assert {:ok, _user} = Users.admin_update_user(user, %{})
    end

    test "allows changing user password" do
      user = UsersFixtures.create_user()

      attrs =
        UsersFixtures.user_attrs()
        |> Map.take([:password, :password_confirmation])

      assert {:ok, updated_user} = Users.admin_update_user(user, attrs)

      assert updated_user.password_hash != user.password_hash
    end

    test "allows changing user email" do
      user = UsersFixtures.create_user()

      attrs =
        UsersFixtures.user_attrs()
        |> Map.take([:email])

      assert {:ok, updated_user} = Users.admin_update_user(user, attrs)

      assert updated_user.email == attrs.email
      assert updated_user.email != user.email
    end

    # XXX: This doesn't feel right as the outcome is a completely new user
    test "allows changing both email and password" do
      user = UsersFixtures.create_user()
      attrs = UsersFixtures.user_attrs()

      assert {:ok, updated_user} = Users.admin_update_user(user, attrs)

      assert updated_user.password_hash != user.password_hash
      assert updated_user.email != user.email
    end

    test "does not allow to clear the password" do
      password = "password1234"
      user = UsersFixtures.create_user(%{password: password})

      attrs = %{
        "password" => nil,
        "password_hash" => nil
      }

      assert {:ok, updated_user} = Users.admin_update_user(user, attrs)
      assert updated_user.password_hash == user.password_hash

      attrs = %{
        "password" => "",
        "password_hash" => ""
      }

      assert {:ok, updated_user} = Users.admin_update_user(user, attrs)
      assert updated_user.password_hash == user.password_hash
    end
  end

  describe "unprivileged_update_self/2" do
    test "returns ok on empty attrs" do
      user = UsersFixtures.create_user()
      assert {:ok, _user} = Users.unprivileged_update_self(user, %{})
    end

    test "allows changing user password" do
      user = UsersFixtures.create_user()

      attrs =
        UsersFixtures.user_attrs()
        |> Map.take([:password, :password_confirmation])

      assert {:ok, updated_user} = Users.unprivileged_update_self(user, attrs)

      assert updated_user.password_hash != user.password_hash
    end

    test "does not allow changing user email" do
      user = UsersFixtures.create_user()

      attrs =
        UsersFixtures.user_attrs()
        |> Map.take([:email])

      assert {:ok, updated_user} = Users.unprivileged_update_self(user, attrs)

      assert updated_user.email != attrs.email
      assert updated_user.email == user.email
    end

    test "does not allow to clear the password" do
      password = "password1234"
      user = UsersFixtures.create_user(%{password: password})

      attrs = %{
        "password" => nil,
        "password_hash" => nil
      }

      assert {:ok, updated_user} = Users.unprivileged_update_self(user, attrs)
      assert updated_user.password_hash == user.password_hash

      attrs = %{
        "password" => "",
        "password_hash" => ""
      }

      assert {:ok, updated_user} = Users.unprivileged_update_self(user, attrs)
      assert updated_user.password_hash == user.password_hash
    end
  end

  describe "update_user_role/2" do
    test "allows to change user role" do
      user = UsersFixtures.create_user()
      assert {:ok, %{role: :unprivileged}} = Users.update_user_role(user, :unprivileged)
      assert {:ok, %{role: :admin}} = Users.update_user_role(user, :admin)
    end

    test "raises on invalid role" do
      user = UsersFixtures.create_user()

      assert {:error, changeset} = Users.update_user_role(user, :foo)
      assert errors_on(changeset) == %{role: ["is invalid"]}
    end
  end

  describe "delete_user/1" do
    test "deletes a user" do
      user = UsersFixtures.create_user()
      assert {:ok, _user} = Users.delete_user(user)
      assert is_nil(Repo.one(Users.User))
    end
  end

  describe "change_user/1" do
    test "returns changeset" do
      user = UsersFixtures.create_user()
      assert %Ecto.Changeset{} = Users.change_user(user)
    end
  end

  describe "as_settings/0" do
    test "returns list of user-id maps" do
      assert Users.as_settings() == MapSet.new([])

      expected_users =
        [
          UsersFixtures.create_user(),
          UsersFixtures.create_user()
        ]
        |> Enum.map(& &1.id)

      assert Users.as_settings() == MapSet.new(expected_users)
    end
  end

  describe "setting_projection/1" do
    test "projects expected fields with user" do
      user = UsersFixtures.create_user()
      assert user.id == Users.setting_projection(user)
    end

    test "projects expected fields with user map" do
      user = UsersFixtures.create_user()
      user_map = Map.from_struct(user)
      assert user.id == Users.setting_projection(user_map)
    end
  end

  describe "update_last_signed_in/2" do
    test "updates last_signed_in_* fields" do
      user = UsersFixtures.create_user()

      {:ok, user} = Users.update_last_signed_in(user, %{provider: :test})
      assert user.last_signed_in_method == "test"

      {:ok, user} = Users.update_last_signed_in(user, %{provider: :another_test})
      assert user.last_signed_in_method == "another_test"
    end
  end

  describe "vpn_session_expires_at/1" do
    test "returns expiration datetime of VPN session" do
      now = DateTime.utc_now()
      Config.put_config!(:vpn_session_duration, 30)

      user =
        UsersFixtures.create_user()
        |> change(%{last_signed_in_at: now})
        |> Repo.update!()

      assert DateTime.diff(Users.vpn_session_expires_at(user), now, :second) in 28..32
    end
  end

  describe "vpn_session_expired?/1" do
    test "returns false when user did not sign in" do
      Config.put_config!(:vpn_session_duration, 30)
      user = UsersFixtures.create_user()
      assert Users.vpn_session_expired?(user) == false
    end

    test "returns false when VPN session is not expired" do
      Config.put_config!(:vpn_session_duration, 30)
      user = UsersFixtures.create_user()

      user =
        user
        |> change(%{last_signed_in_at: DateTime.utc_now()})
        |> Repo.update!()

      assert Users.vpn_session_expired?(user) == false
    end

    test "returns true when VPN session is expired" do
      Config.put_config!(:vpn_session_duration, 30)
      user = UsersFixtures.create_user()

      user =
        user
        |> change(%{last_signed_in_at: DateTime.utc_now() |> DateTime.add(-31, :second)})
        |> Repo.update!()

      assert Users.vpn_session_expired?(user) == true
    end

    test "returns false when VPN session never expires" do
      Config.put_config!(:vpn_session_duration, 0)
      user = UsersFixtures.create_user()

      user =
        user
        |> change(%{last_signed_in_at: ~U[1990-01-01 01:01:01.000001Z]})
        |> Repo.update!()

      assert Users.vpn_session_expired?(user) == false
    end
  end
end
