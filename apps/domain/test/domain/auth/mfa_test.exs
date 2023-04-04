defmodule Domain.Auth.MFATest do
  use Domain.DataCase, async: true
  alias Domain.UsersFixtures
  alias Domain.MFAFixtures
  alias Domain.Auth.MFA

  describe "count_users_with_mfa_enabled/0" do
    test "returns 0 when there are no methods" do
      assert MFA.count_users_with_mfa_enabled() == 0
    end

    test "returns count of users with at least one method" do
      MFAFixtures.create_totp_method()
      MFAFixtures.create_totp_method()

      user = UsersFixtures.create_user_with_role(:admin)
      MFAFixtures.create_totp_method(user: user)
      MFAFixtures.create_totp_method(user: user)

      assert MFA.count_users_with_mfa_enabled() == 3
    end
  end

  describe "fetch_method_by_id/1" do
    test "returns error when method is not found" do
      assert MFA.fetch_method_by_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUIDv4" do
      assert MFA.fetch_method_by_id("foo") == {:error, :not_found}
    end

    test "returns method by id" do
      method = MFAFixtures.create_totp_method()
      assert {:ok, returned_method} = MFA.fetch_method_by_id(method.id)
      assert returned_method.id == method.id
      refute returned_method.code
    end
  end

  describe "fetch_last_used_method_by_user_id/1" do
    test "returns error when method user id is not found" do
      assert MFA.fetch_last_used_method_by_user_id(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "returns error when user id is not a valid UUIDv4" do
      assert MFA.fetch_last_used_method_by_user_id("foo") == {:error, :not_found}
    end

    test "returns method by user id" do
      user = UsersFixtures.create_user_with_role(:admin)
      method = MFAFixtures.create_totp_method(user: user)
      assert {:ok, returned_method} = MFA.fetch_last_used_method_by_user_id(user.id)
      assert returned_method.id == method.id
    end
  end

  describe "list_methods_for_user/1" do
    test "returns empty list when there are no methods" do
      user = UsersFixtures.create_user_with_role(:admin)
      assert MFA.list_methods_for_user(user) == {:ok, []}
    end

    test "returns empty list when user has no methods" do
      MFAFixtures.create_totp_method()
      user = UsersFixtures.create_user_with_role(:admin)
      assert MFA.list_methods_for_user(user) == {:ok, []}
    end

    test "returns methods for user" do
      user = UsersFixtures.create_user_with_role(:admin)
      method1 = MFAFixtures.create_totp_method(user: user)
      method2 = MFAFixtures.create_totp_method(user: user)

      assert {:ok, methods} = MFA.list_methods_for_user(user)

      assert Enum.count(methods) == 2
      assert Enum.sort([method1.id, method2.id]) == Enum.sort(Enum.map(methods, & &1.id))
    end
  end

  describe "delete_method_by_id/2" do
    test "returns error when method is not found" do
      user = UsersFixtures.create_user_with_role(:admin)
      assert MFA.delete_method_by_id(Ecto.UUID.generate(), user) == {:error, :not_found}
    end

    test "returns error when id is not a valid UUIDv4" do
      user = UsersFixtures.create_user_with_role(:admin)
      assert MFA.delete_method_by_id("foo", user) == {:error, :not_found}
    end

    test "deletes method by id" do
      user = UsersFixtures.create_user_with_role(:admin)
      method = MFAFixtures.create_totp_method(user: user)
      assert {:ok, deleted_method} = MFA.delete_method_by_id(method.id, user)
      assert deleted_method.id == method.id
      refute Repo.one(MFA.Method)
    end

    test "does not allow to delete method that belongs to other user" do
      method = MFAFixtures.create_totp_method()
      user = UsersFixtures.create_user_with_role(:admin)
      assert MFA.delete_method_by_id(method.id, user) == {:error, :not_found}
      assert Repo.one(MFA.Method)
    end
  end

  describe "create_method/2" do
    test "returns changeset error when required attrs are missing" do
      user = UsersFixtures.create_user_with_role(:admin)

      assert {:error, changeset} = MFA.create_method(%{}, user.id)
      refute changeset.valid?

      assert errors_on(changeset) == %{
               code: ["can't be blank"],
               name: ["can't be blank"],
               payload: ["can't be blank"],
               type: ["can't be blank"]
             }
    end

    test "returns error on invalid attrs" do
      user = UsersFixtures.create_user_with_role(:admin)

      attrs = %{
        type: :insecure,
        payload: %{},
        code: 10
      }

      assert {:error, changeset} = MFA.create_method(attrs, user.id)
      refute changeset.valid?

      assert errors_on(changeset) == %{
               code: ["is invalid"],
               type: ["is invalid"],
               name: ["can't be blank"]
             }

      attrs = %{payload: %{}, code: "10"}
      assert {:error, changeset} = MFA.create_method(attrs, user.id)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).payload

      attrs = MFAFixtures.totp_method_attrs(code: "10")
      assert {:error, changeset} = MFA.create_method(attrs, user.id)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).code
    end

    test "returns error when name is already taken" do
      user = UsersFixtures.create_user_with_role(:admin)

      attrs = MFAFixtures.totp_method_attrs()
      assert {:ok, _user} = MFA.create_method(attrs, user.id)
      assert {:error, changeset} = MFA.create_method(attrs, user.id)
      refute changeset.valid?
      assert "has already been taken" in errors_on(changeset).name
    end

    test "does not return error when other user has the same name" do
      user = UsersFixtures.create_user_with_role(:admin)
      other_user = UsersFixtures.create_user_with_role(:admin)

      attrs = MFAFixtures.totp_method_attrs()
      assert {:ok, _user} = MFA.create_method(attrs, user.id)
      assert {:ok, _user} = MFA.create_method(attrs, other_user.id)
    end

    test "creates a TOTP MFA method" do
      user = UsersFixtures.create_user_with_role(:admin)
      attrs = MFAFixtures.totp_method_attrs()
      assert {:ok, method} = MFA.create_method(attrs, user.id)

      assert method.name == attrs.name
      assert method.type == attrs.type
      assert method.payload == attrs.payload
      assert method.user_id == user.id
      refute method.code
    end

    test "trims name" do
      user = UsersFixtures.create_user_with_role(:admin)

      attrs = MFAFixtures.totp_method_attrs()
      updated_attrs = Map.put(attrs, :name, " #{attrs.name} ")

      assert {:ok, user} = MFA.create_method(updated_attrs, user.id)
      assert user.name == attrs.name
    end
  end

  describe "use_method/2" do
    test "returns changeset error when required attrs are missing" do
      attrs = MFAFixtures.totp_method_attrs()
      method = MFAFixtures.create_totp_method(attrs)

      assert {:error, changeset} = MFA.use_method(method, %{})
      refute changeset.valid?

      assert errors_on(changeset) == %{
               code: ["can't be blank"]
             }
    end

    test "returns error on invalid code" do
      attrs = MFAFixtures.totp_method_attrs()
      method = MFAFixtures.create_totp_method(attrs)

      assert {:error, changeset} = MFA.use_method(method, %{"code" => "123456"})
      refute changeset.valid?

      assert errors_on(changeset) == %{
               code: ["is invalid"]
             }
    end

    test "uses the code and updated last_used_at" do
      attrs = MFAFixtures.totp_method_attrs()

      method =
        MFAFixtures.create_totp_method(attrs)
        |> MFAFixtures.rotate_totp_method_key()

      assert {:ok, updated_method} = MFA.use_method(method, %{"code" => attrs.code})

      assert DateTime.compare(updated_method.last_used_at, method.last_used_at) in [:gt, :eq]
    end
  end
end
