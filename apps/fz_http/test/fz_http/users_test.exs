defmodule FzHttp.UsersTest do
  use FzHttp.DataCase, async: true
  import FzHttp.Users
  alias FzHttp.SubjectFixtures
  alias FzHttp.UsersFixtures
  alias FzHttp.DevicesFixtures
  alias FzHttp.Config
  alias FzHttp.Users

  describe "count/0" do
    test "returns correct count of all users" do
      assert count() == 0

      UsersFixtures.create_user_with_role(:unprivileged)
      assert count() == 1

      UsersFixtures.create_user_with_role(:admin)
      assert count() == 2
    end
  end

  describe "fetch_count_by_role/0" do
    setup do
      subject =
        SubjectFixtures.new()
        |> SubjectFixtures.set_permissions([
          Users.Authorizer.manage_users_permission()
        ])

      %{subject: subject}
    end

    test "returns 0 when there are no users", %{subject: subject} do
      assert fetch_count_by_role(:unprivileged, subject) == 0
      assert fetch_count_by_role(:admin, subject) == 0
    end

    test "returns correct count of admin users", %{subject: subject} do
      UsersFixtures.create_user_with_role(:admin)
      assert fetch_count_by_role(:admin, subject) == 1
      assert fetch_count_by_role(:unprivileged, subject) == 0

      UsersFixtures.create_user_with_role(:unprivileged)
      assert fetch_count_by_role(:admin, subject) == 1
      assert fetch_count_by_role(:unprivileged, subject) == 1

      for _ <- 1..5, do: UsersFixtures.create_user_with_role(:unprivileged)
      assert fetch_count_by_role(:admin, subject) == 1
      assert fetch_count_by_role(:unprivileged, subject) == 6
    end

    test "returns error when subject can not view users", %{subject: subject} do
      subject = SubjectFixtures.remove_permissions(subject)

      assert fetch_count_by_role(:foo, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Users.Authorizer.manage_users_permission()]]}}
    end
  end

  describe "fetch_user_by_id/2" do
    test "returns error when user is not found" do
      subject = SubjectFixtures.create_subject()
      assert fetch_user_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUIDv4" do
      subject = SubjectFixtures.create_subject()
      assert fetch_user_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns user" do
      user = UsersFixtures.create_user_with_role(:admin)
      subject = SubjectFixtures.create_subject()
      assert {:ok, returned_user} = fetch_user_by_id(user.id, subject)
      assert returned_user.id == user.id
    end

    test "returns error when subject can not view users" do
      subject = SubjectFixtures.create_subject()
      subject = SubjectFixtures.remove_permissions(subject)

      assert fetch_user_by_id("foo", subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Users.Authorizer.manage_users_permission()]]}}
    end
  end

  describe "fetch_user_by_id/1" do
    test "returns error when user is not found" do
      assert fetch_user_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUIDv4" do
      assert fetch_user_by_id("foo") == {:error, :not_found}
    end

    test "returns user" do
      user = UsersFixtures.create_user_with_role(:admin)
      assert {:ok, returned_user} = fetch_user_by_id(user.id)
      assert returned_user.id == user.id
    end
  end

  describe "fetch_user_by_id!/1" do
    test "raises when user is not found" do
      assert_raise(Ecto.NoResultsError, fn ->
        fetch_user_by_id!(Ecto.UUID.generate())
      end)
    end

    test "raises when id is not a valid UUIDv4" do
      assert_raise(Ecto.Query.CastError, fn ->
        assert fetch_user_by_id!("foo")
      end)
    end

    test "returns user" do
      user = UsersFixtures.create_user_with_role(:admin)
      assert returned_user = fetch_user_by_id!(user.id)
      assert returned_user.id == user.id
    end
  end

  describe "fetch_user_by_email/1" do
    test "returns error when user is not found" do
      assert fetch_user_by_email("foo@bar") == {:error, :not_found}
    end

    test "returns user" do
      user = UsersFixtures.create_user_with_role(:admin)
      assert {:ok, returned_user} = fetch_user_by_email(user.email)
      assert returned_user.id == user.id
    end

    test "email is not case sensitive" do
      user = UsersFixtures.create_user_with_role(:admin)
      assert {:ok, user} = fetch_user_by_email(String.upcase(user.email))
      assert {:ok, ^user} = fetch_user_by_email(String.downcase(user.email))
    end
  end

  describe "fetch_user_by_id_or_email/2" do
    setup do
      subject = SubjectFixtures.create_subject()
      %{subject: subject}
    end

    test "returns error when user is not found", %{subject: subject} do
      assert fetch_user_by_id_or_email(Ecto.UUID.generate(), subject) == {:error, :not_found}
      assert fetch_user_by_id_or_email("foo@bar.com", subject) == {:error, :not_found}
      assert fetch_user_by_id_or_email("foo", subject) == {:error, :not_found}
    end

    test "returns user by id", %{subject: subject} do
      user = UsersFixtures.create_user_with_role(:admin)
      assert {:ok, returned_user} = fetch_user_by_id_or_email(user.id, subject)
      assert returned_user.id == user.id
    end

    test "returns user by email", %{subject: subject} do
      user = UsersFixtures.create_user_with_role(:admin)
      assert {:ok, returned_user} = fetch_user_by_id_or_email(user.email, subject)
      assert returned_user.id == user.id
    end

    test "returns error when subject can not view users", %{subject: subject} do
      subject = SubjectFixtures.remove_permissions(subject)

      assert fetch_user_by_id_or_email("foo", subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Users.Authorizer.manage_users_permission()]]}}
    end
  end

  describe "list_users/2" do
    test "returns empty list when there are not users" do
      subject =
        SubjectFixtures.new()
        |> SubjectFixtures.set_permissions([
          Users.Authorizer.manage_users_permission()
        ])

      assert list_users(subject) == {:ok, []}
      assert list_users(subject, hydrate: [:device_count]) == {:ok, []}
    end

    test "returns list of users in all roles" do
      user1 = UsersFixtures.create_user_with_role(:admin)
      user2 = UsersFixtures.create_user_with_role(:unprivileged)

      subject = SubjectFixtures.create_subject(user1)

      assert {:ok, users} = list_users(subject)
      assert length(users) == 2
      assert Enum.sort(Enum.map(users, & &1.id)) == Enum.sort([user1.id, user2.id])
    end

    test "hydrates users with device count" do
      user1 = UsersFixtures.create_user_with_role(:admin)
      subject = SubjectFixtures.create_subject(user1)
      DevicesFixtures.create_device(user: user1, subject: subject)

      user2 = UsersFixtures.create_user_with_role(:unprivileged)
      DevicesFixtures.create_device(user: user2, subject: subject)
      DevicesFixtures.create_device(user: user2, subject: subject)

      assert {:ok, users} = list_users(subject, hydrate: [:device_count])
      assert length(users) == 2

      assert Enum.sort(Enum.map(users, &{&1.id, &1.device_count})) ==
               Enum.sort([{user1.id, 1}, {user2.id, 2}])

      assert {:ok, users} = list_users(subject, hydrate: [:device_count, :device_count])

      assert Enum.sort(Enum.map(users, &{&1.id, &1.device_count})) ==
               Enum.sort([{user1.id, 1}, {user2.id, 2}])
    end

    test "returns error when subject can not view users" do
      subject = SubjectFixtures.create_subject()
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_users(subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Users.Authorizer.manage_users_permission()]]}}
    end
  end

  describe "request_sign_in_token/1" do
    test "returns user with updated sign-in token" do
      user = UsersFixtures.create_user_with_role(:admin)
      refute user.sign_in_token_hash

      assert {:ok, user} = request_sign_in_token(user)
      assert user.sign_in_token
      assert user.sign_in_token_hash
      assert user.sign_in_token_created_at
    end
  end

  describe "consume_sign_in_token/1" do
    test "returns user when token is valid" do
      {:ok, user} =
        UsersFixtures.create_user_with_role(:admin)
        |> request_sign_in_token()

      assert {:ok, signed_in_user} = consume_sign_in_token(user, user.sign_in_token)
      assert signed_in_user.id == user.id
    end

    test "clears the sign in token when consumed" do
      {:ok, user} =
        UsersFixtures.create_user_with_role(:admin)
        |> request_sign_in_token()

      assert {:ok, user} = consume_sign_in_token(user, user.sign_in_token)
      assert is_nil(user.sign_in_token)
      assert is_nil(user.sign_in_token_created_at)

      assert user = Repo.one(Users.User)
      assert is_nil(user.sign_in_token)
      assert is_nil(user.sign_in_token_created_at)
    end

    test "returns error when token doesn't exist" do
      user = UsersFixtures.create_user_with_role(:admin)

      assert consume_sign_in_token(user, "foo") == {:error, :no_token}
    end

    test "token expires in one hour" do
      about_one_hour_ago =
        DateTime.utc_now()
        |> DateTime.add(-1, :hour)
        |> DateTime.add(30, :second)

      {:ok, user} =
        UsersFixtures.create_user_with_role(:admin)
        |> request_sign_in_token()

      user
      |> Ecto.Changeset.change(sign_in_token_created_at: about_one_hour_ago)
      |> Repo.update!()

      assert {:ok, _user} = consume_sign_in_token(user, user.sign_in_token)
    end

    test "returns error when token is expired" do
      one_hour_and_one_second_ago =
        DateTime.utc_now()
        |> DateTime.add(-1, :hour)
        |> DateTime.add(-1, :second)

      {:ok, user} =
        UsersFixtures.create_user_with_role(:admin)
        |> request_sign_in_token()

      user =
        user
        |> Ecto.Changeset.change(sign_in_token_created_at: one_hour_and_one_second_ago)
        |> Repo.update!()

      assert consume_sign_in_token(user, user.sign_in_token) == {:error, :token_expired}
    end
  end

  describe "create_user/3" do
    setup do
      subject = SubjectFixtures.create_subject()
      %{subject: subject}
    end

    test "returns changeset error when required attrs are missing", %{subject: subject} do
      assert {:error, changeset} = create_user(:unprivileged, %{}, subject)
      refute changeset.valid?

      assert errors_on(changeset) == %{email: ["can't be blank"]}
    end

    test "returns error on invalid attrs", %{subject: subject} do
      assert {:error, changeset} =
               create_user(:unprivileged, %{email: "invalid_email", password: "short"}, subject)

      refute changeset.valid?

      assert errors_on(changeset) == %{
               email: ["is invalid email address"],
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["can't be blank"]
             }

      assert {:error, changeset} =
               create_user(
                 :unprivileged,
                 %{email: "invalid_email", password: String.duplicate("A", 65)},
                 subject
               )

      refute changeset.valid?
      assert "should be at most 64 character(s)" in errors_on(changeset).password

      assert {:error, changeset} =
               create_user(:unprivileged, %{email: String.duplicate(" ", 18)}, subject)

      refute changeset.valid?

      assert "can't be blank" in errors_on(changeset).email
    end

    test "requires password confirmation to match the password", %{subject: subject} do
      assert {:error, changeset} =
               create_user(
                 :unprivileged,
                 %{password: "foo", password_confirmation: "bar"},
                 subject
               )

      assert "does not match confirmation" in errors_on(changeset).password_confirmation

      assert {:error, changeset} =
               create_user(
                 :unprivileged,
                 %{
                   password: "password1234",
                   password_confirmation: "password1234"
                 },
                 subject
               )

      refute Map.has_key?(errors_on(changeset), :password_confirmation)
    end

    test "returns error when email is already taken", %{subject: subject} do
      attrs = UsersFixtures.user_attrs()
      assert {:ok, _user} = create_user(:unprivileged, attrs, subject)
      assert {:error, changeset} = create_user(:unprivileged, attrs, subject)
      refute changeset.valid?
      assert "has already been taken" in errors_on(changeset).email
    end

    test "returns error when role is invalid", %{subject: subject} do
      attrs = UsersFixtures.user_attrs()

      assert_raise Ecto.ChangeError, fn ->
        create_user(:foo, attrs, subject)
      end
    end

    test "creates a user in given role", %{subject: subject} do
      for role <- [:admin, :unprivileged] do
        attrs = UsersFixtures.user_attrs()
        assert {:ok, user} = create_user(role, attrs, subject)
        assert user.role == role
      end
    end

    test "creates an unprivileged user", %{subject: subject} do
      attrs = UsersFixtures.user_attrs()
      assert {:ok, user} = create_user(:unprivileged, attrs, subject)
      assert user.role == :unprivileged
      assert user.email == attrs.email

      assert FzHttp.Crypto.equal?(attrs.password, user.password_hash)
      assert is_nil(user.password)
      assert is_nil(user.password_confirmation)

      assert is_nil(user.last_signed_in_at)
      assert is_nil(user.last_signed_in_method)
      assert is_nil(user.sign_in_token)
      assert is_nil(user.sign_in_token_hash)
      assert is_nil(user.sign_in_token_created_at)
    end

    test "allows creating a user without password", %{subject: subject} do
      email = UsersFixtures.user_attrs().email
      attrs = %{email: email, password: nil, password_confirmation: nil}
      assert {:ok, user} = create_user(:unprivileged, attrs, subject)
      assert is_nil(user.password_hash)

      email = UsersFixtures.user_attrs().email
      attrs = %{email: email, password: "", password_confirmation: ""}
      assert {:ok, user} = create_user(:unprivileged, attrs, subject)
      assert is_nil(user.password_hash)
    end

    test "trims email", %{subject: subject} do
      attrs = UsersFixtures.user_attrs()
      updated_attrs = Map.put(attrs, :email, " #{attrs.email} ")

      assert {:ok, user} = create_user(:unprivileged, updated_attrs, subject)

      assert user.email == attrs.email
    end

    test "returns error when subject can not create users", %{subject: subject} do
      subject = SubjectFixtures.remove_permissions(subject)

      assert create_user(:foo, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Users.Authorizer.manage_users_permission()]]}}
    end
  end

  describe "change_user/1" do
    test "returns changeset" do
      user = UsersFixtures.create_user_with_role(:admin)
      assert %Ecto.Changeset{} = change_user(user)
    end
  end

  describe "update_user/3" do
    setup do
      unprivileged_user = UsersFixtures.create_user_with_role(:unprivileged)

      admin_user = UsersFixtures.create_user_with_role(:admin)
      admin_subject = SubjectFixtures.create_subject(admin_user)

      %{
        unprivileged_user: unprivileged_user,
        admin_user: admin_user,
        subject: admin_subject
      }
    end

    test "noop on empty attrs", %{
      unprivileged_user: user,
      subject: subject
    } do
      assert {:ok, _user} = update_user(user, %{}, subject)
    end

    test "allows admin to change user password", %{subject: subject} do
      user = UsersFixtures.create_user_with_role(:admin)

      attrs =
        UsersFixtures.user_attrs()
        |> Map.take([:password, :password_confirmation])

      assert {:ok, updated_user} = update_user(user, attrs, subject)

      assert updated_user.password_hash != user.password_hash
    end

    test "allows admin to change user email", %{unprivileged_user: user, subject: subject} do
      attrs =
        UsersFixtures.user_attrs()
        |> Map.take([:email])

      assert {:ok, updated_user} = update_user(user, attrs, subject)

      assert updated_user.email == attrs.email
      assert updated_user.email != user.email
    end

    test "allows admin to change both email and password", %{
      unprivileged_user: user,
      subject: subject
    } do
      attrs = UsersFixtures.user_attrs()

      assert {:ok, updated_user} = update_user(user, attrs, subject)

      assert updated_user.password_hash != user.password_hash
      assert updated_user.email != user.email
    end

    test "allows admin to change user role", %{subject: subject} do
      user = UsersFixtures.create_user_with_role(:admin)
      assert {:ok, %{role: :unprivileged}} = update_user(user, %{role: :unprivileged}, subject)
      assert {:ok, %{role: :admin}} = update_user(user, %{role: :admin}, subject)
    end

    test "raises on invalid role", %{subject: subject} do
      user = UsersFixtures.create_user_with_role(:admin)

      assert {:error, changeset} = update_user(user, %{role: :foo}, subject)
      assert errors_on(changeset) == %{role: ["is invalid"]}
    end

    test "does not allow to clear the password", %{subject: subject} do
      password = "password1234"
      user = UsersFixtures.create_user_with_role(:admin, %{password: password})

      attrs = %{
        "password" => nil,
        "password_hash" => nil
      }

      assert {:ok, updated_user} = update_user(user, attrs, subject)
      assert updated_user.password_hash == user.password_hash

      attrs = %{
        "password" => "",
        "password_hash" => ""
      }

      assert {:ok, updated_user} = update_user(user, attrs, subject)
      assert updated_user.password_hash == user.password_hash
    end

    test "returns error when subject can not update users", %{
      unprivileged_user: user,
      subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert update_user(user, %{}, subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     Users.Authorizer.manage_users_permission()
                   ]
                 ]}}
    end
  end

  describe "update_self/2" do
    setup do
      user = UsersFixtures.create_user_with_role(:unprivileged)
      subject = SubjectFixtures.create_subject(user)

      %{
        user: user,
        subject: subject
      }
    end

    test "noop on empty attrs", %{
      subject: subject
    } do
      assert {:ok, _user} = update_self(%{}, subject)
    end

    test "does not allow to clear the password" do
      password = "password1234"
      user = UsersFixtures.create_user_with_role(:admin, %{password: password})
      subject = SubjectFixtures.create_subject(user)

      attrs = %{
        "password" => nil,
        "password_hash" => nil
      }

      assert {:ok, updated_user} = update_self(attrs, subject)
      assert updated_user.password_hash == user.password_hash

      attrs = %{
        "password" => "",
        "password_hash" => ""
      }

      assert {:ok, updated_user} = update_self(attrs, subject)
      assert updated_user.password_hash == user.password_hash
    end

    test "allows unprivileged user to change own password", %{
      user: user,
      subject: subject
    } do
      attrs =
        UsersFixtures.user_attrs()
        |> Map.take([:password, :password_confirmation])

      assert {:ok, updated_user} = update_self(attrs, subject)

      assert updated_user.password_hash != user.password_hash
    end

    test "does not allow unprivileged user to change own email", %{
      user: user,
      subject: subject
    } do
      attrs =
        UsersFixtures.user_attrs()
        |> Map.take([:email])

      assert {:ok, updated_user} = update_self(attrs, subject)

      assert updated_user.email != attrs.email
      assert updated_user.email == user.email
    end

    test "returns error when subject can not update own profile", %{
      subject: subject
    } do
      subject = SubjectFixtures.remove_permissions(subject)

      assert update_self(%{}, subject) ==
               {:error,
                {:unauthorized,
                 [
                   missing_permissions: [
                     Users.Authorizer.edit_own_profile_permission()
                   ]
                 ]}}
    end
  end

  describe "delete_user/1" do
    test "deletes a user" do
      user = UsersFixtures.create_user_with_role(:admin)
      subject = SubjectFixtures.create_subject(user)

      assert {:ok, _user} = delete_user(user, subject)
      assert is_nil(Repo.one(Users.User))
    end

    test "returns error when subject can not delete users" do
      user = UsersFixtures.create_user_with_role(:admin)

      subject =
        user
        |> SubjectFixtures.create_subject()
        |> SubjectFixtures.remove_permissions()

      assert delete_user(user, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Users.Authorizer.manage_users_permission()]]}}
    end
  end

  describe "setting_projection/1" do
    test "projects expected fields with user" do
      user = UsersFixtures.create_user_with_role(:admin)
      assert user.id == setting_projection(user)
    end

    test "projects expected fields with user map" do
      user = UsersFixtures.create_user_with_role(:admin)
      user_map = Map.from_struct(user)
      assert user.id == setting_projection(user_map)
    end
  end

  describe "as_settings/0" do
    test "returns list of user-id maps" do
      assert as_settings() == MapSet.new([])

      expected_settings =
        [
          UsersFixtures.create_user_with_role(:admin),
          UsersFixtures.create_user_with_role(:admin)
        ]
        |> Enum.map(&setting_projection/1)
        |> MapSet.new()

      assert as_settings() == expected_settings
    end
  end

  describe "update_last_signed_in/2" do
    test "updates last_signed_in_* fields" do
      user = UsersFixtures.create_user_with_role(:admin)

      assert {:ok, user} = update_last_signed_in(user, %{provider: :test})
      assert user.last_signed_in_method == "test"

      assert {:ok, user} = update_last_signed_in(user, %{provider: :another_test})
      assert user.last_signed_in_method == "another_test"
    end
  end

  describe "vpn_session_expires_at/1" do
    test "returns expiration datetime of VPN session" do
      now = DateTime.utc_now()
      Config.put_config!(:vpn_session_duration, 30)

      user =
        UsersFixtures.create_user_with_role(:admin)
        |> change(%{last_signed_in_at: now})
        |> Repo.update!()

      assert DateTime.diff(vpn_session_expires_at(user), now, :second) in 28..32
    end
  end

  describe "vpn_session_expired?/1" do
    test "returns false when user did not sign in" do
      Config.put_config!(:vpn_session_duration, 30)
      user = UsersFixtures.create_user_with_role(:admin)
      assert vpn_session_expired?(user) == false
    end

    test "returns false when VPN session is not expired" do
      Config.put_config!(:vpn_session_duration, 30)
      user = UsersFixtures.create_user_with_role(:admin)

      user =
        user
        |> change(%{last_signed_in_at: DateTime.utc_now()})
        |> Repo.update!()

      assert vpn_session_expired?(user) == false
    end

    test "returns true when VPN session is expired" do
      Config.put_config!(:vpn_session_duration, 30)
      user = UsersFixtures.create_user_with_role(:admin)

      user =
        user
        |> change(%{last_signed_in_at: DateTime.utc_now() |> DateTime.add(-31, :second)})
        |> Repo.update!()

      assert vpn_session_expired?(user) == true
    end

    test "returns false when VPN session never expires" do
      Config.put_config!(:vpn_session_duration, 0)
      user = UsersFixtures.create_user_with_role(:admin)

      user =
        user
        |> change(%{last_signed_in_at: ~U[1990-01-01 01:01:01.000001Z]})
        |> Repo.update!()

      assert vpn_session_expired?(user) == false
    end
  end
end
