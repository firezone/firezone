defmodule FzHttp.ApiTokensTest do
  use FzHttp.DataCase, async: true
  import FzHttp.ApiTokens
  alias FzHttp.ApiTokens.{ApiToken, Authorizer}
  alias FzHttp.ApiTokensFixtures
  alias FzHttp.SubjectFixtures
  alias FzHttp.UsersFixtures

  setup do
    user = UsersFixtures.create_user_with_role(:admin)
    subject = SubjectFixtures.create_subject(user)

    %{user: user, subject: subject}
  end

  describe "count_by_user_id/1" do
    test "returns 0 when no user exist" do
      assert count_by_user_id(Ecto.UUID.generate()) == 0
    end

    test "returns the number of api_tokens for a user" do
      user = UsersFixtures.create_user()
      assert count_by_user_id(user.id) == 0

      ApiTokensFixtures.create_api_token(user: user)
      assert count_by_user_id(user.id) == 1

      ApiTokensFixtures.create_api_token(user: user)
      assert count_by_user_id(user.id) == 2
    end
  end

  describe "list_api_tokens/1" do
    test "returns empty list when there are no api tokens", %{subject: subject} do
      assert list_api_tokens(subject) == {:ok, []}
    end

    test "does not return api tokens when user has no access to them", %{subject: subject} do
      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())

      # |> SubjectFixtures.add_permission(Authorizer.manage_owned_api_tokens_permission())

      ApiTokensFixtures.create_api_token()
      assert list_api_tokens(subject) == {:ok, []}
    end

    test "returns other user api tokens when subject has manage permission", %{subject: subject} do
      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())
        |> SubjectFixtures.add_permission(Authorizer.manage_api_tokens_permission())

      api_token = ApiTokensFixtures.create_api_token()

      assert list_api_tokens(subject) == {:ok, [api_token]}
    end

    test "returns all api tokens for a user", %{user: user, subject: subject} do
      api_token = ApiTokensFixtures.create_api_token(user: user)
      assert list_api_tokens(subject) == {:ok, [api_token]}

      ApiTokensFixtures.create_api_token(user: user)
      assert {:ok, api_tokens} = list_api_tokens(subject)
      assert length(api_tokens) == 2
    end

    test "returns error when subject has no permission to view api tokens", %{subject: subject} do
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_api_tokens(subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.view_api_tokens_permission()]]}}
    end
  end

  describe "list_api_tokens_by_user_id/2" do
    test "returns api token that belongs to another user with manage permission", %{
      subject: subject
    } do
      api_token = ApiTokensFixtures.create_api_token()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())
        |> SubjectFixtures.add_permission(Authorizer.manage_api_tokens_permission())

      assert list_api_tokens_by_user_id(api_token.user_id, subject) ==
               {:ok, [api_token]}
    end

    test "does not return api token that belongs to another user with manage_owned permission", %{
      subject: subject
    } do
      api_token = ApiTokensFixtures.create_api_token()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())
        |> SubjectFixtures.add_permission(Authorizer.manage_owned_api_tokens_permission())

      assert list_api_tokens_by_user_id(api_token.user_id, subject) == {:ok, []}
    end

    test "returns api tokens scoped to a user", %{user: user, subject: subject} do
      ApiTokensFixtures.create_api_token(user: user)
      ApiTokensFixtures.create_api_token(user: user)

      assert {:ok, api_tokens} = list_api_tokens_by_user_id(user.id, subject)
      assert length(api_tokens) == 2
    end

    test "returns error when api token does not exist", %{subject: subject} do
      assert list_api_tokens_by_user_id(Ecto.UUID.generate(), subject) == {:ok, []}
    end

    test "returns error when user ID is not a valid UUID", %{subject: subject} do
      assert list_api_tokens_by_user_id("foo", subject) == {:ok, []}
    end

    test "returns error when subject has no permission to view api tokens", %{subject: subject} do
      subject = SubjectFixtures.remove_permissions(subject)

      assert list_api_tokens_by_user_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.view_api_tokens_permission()]]}}
    end
  end

  describe "fetch_api_token_by_id/2" do
    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_api_token_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns api token by id", %{user: user, subject: subject} do
      api_token = ApiTokensFixtures.create_api_token(user: user)
      assert fetch_api_token_by_id(api_token.id, subject) == {:ok, api_token}
    end

    test "returns api token that belongs to another user with manage permission", %{
      subject: subject
    } do
      api_token = ApiTokensFixtures.create_api_token()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())
        |> SubjectFixtures.add_permission(Authorizer.manage_api_tokens_permission())

      assert fetch_api_token_by_id(api_token.id, subject) == {:ok, api_token}
    end

    test "does not return api token that belongs to another user with manage_owned permission", %{
      subject: subject
    } do
      api_token = ApiTokensFixtures.create_api_token()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())
        |> SubjectFixtures.add_permission(Authorizer.manage_owned_api_tokens_permission())

      assert fetch_api_token_by_id(api_token.id, subject) == {:error, :not_found}
    end

    test "returns error when api token does not exist", %{subject: subject} do
      assert fetch_api_token_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view api tokens", %{subject: subject} do
      subject = SubjectFixtures.remove_permissions(subject)

      assert fetch_api_token_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.view_api_tokens_permission()]]}}
    end
  end

  describe "fetch_unexpired_api_token_by_id/2" do
    test "returns error when UUID is invalid", %{subject: subject} do
      assert fetch_unexpired_api_token_by_id("foo", subject) == {:error, :not_found}
    end

    test "returns api token by id", %{user: user, subject: subject} do
      api_token = ApiTokensFixtures.create_api_token(user: user)
      assert fetch_unexpired_api_token_by_id(api_token.id, subject) == {:ok, api_token}
    end

    test "returns error for expired token", %{user: user, subject: subject} do
      api_token =
        ApiTokensFixtures.create_api_token(user: user, expires_in: 1)
        |> ApiTokensFixtures.expire_api_token()

      assert fetch_unexpired_api_token_by_id(api_token.id, subject) ==
               {:error, :not_found}
    end

    test "returns api token that belongs to another user with manage permission", %{
      subject: subject
    } do
      api_token = ApiTokensFixtures.create_api_token()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())
        |> SubjectFixtures.add_permission(Authorizer.manage_api_tokens_permission())

      assert fetch_unexpired_api_token_by_id(api_token.id, subject) == {:ok, api_token}
    end

    test "does not return api token that belongs to another user with manage_owned permission", %{
      subject: subject
    } do
      api_token = ApiTokensFixtures.create_api_token()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())
        |> SubjectFixtures.add_permission(Authorizer.manage_owned_api_tokens_permission())

      assert fetch_unexpired_api_token_by_id(api_token.id, subject) ==
               {:error, :not_found}
    end

    test "returns error when api token does not exist", %{subject: subject} do
      assert fetch_unexpired_api_token_by_id(Ecto.UUID.generate(), subject) ==
               {:error, :not_found}
    end

    test "returns error when subject has no permission to view api tokens", %{subject: subject} do
      subject = SubjectFixtures.remove_permissions(subject)

      assert fetch_unexpired_api_token_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.view_api_tokens_permission()]]}}
    end
  end

  describe "fetch_unexpired_api_token_by_id/1" do
    test "fetches the unexpired token" do
      api_token = ApiTokensFixtures.create_api_token()
      assert fetch_unexpired_api_token_by_id(api_token.id) == {:ok, api_token}
    end

    test "returns error for expired token" do
      api_token =
        ApiTokensFixtures.create_api_token(%{"expires_in" => 1})
        |> ApiTokensFixtures.expire_api_token()

      assert fetch_unexpired_api_token_by_id(api_token.id) == {:error, :not_found}
    end
  end

  describe "new_api_token/1" do
    test "returns api token changeset" do
      assert %Ecto.Changeset{data: %ApiToken{}, changes: changes} = new_api_token()
      assert Map.has_key?(changes, :expires_at)
    end
  end

  describe "create_api_token/2" do
    test "creates an api_token", %{user: user, subject: subject} do
      attrs = %{
        "expires_in" => 1
      }

      assert {:ok, %ApiToken{} = api_token} = create_api_token(attrs, subject)

      # Within 10 seconds
      assert_in_delta DateTime.to_unix(api_token.expires_at),
                      DateTime.to_unix(DateTime.add(DateTime.utc_now(), 1, :day)),
                      10

      assert api_token.user_id == user.id
      assert api_token.expires_in == 1
    end

    test "returns changeset error on invalid data", %{subject: subject} do
      attrs = %{
        "expires_in" => 0
      }

      assert {:error, %Ecto.Changeset{} = changeset} = create_api_token(attrs, subject)

      assert changeset.valid? == false
      assert errors_on(changeset) == %{expires_in: ["must be greater than or equal to 1"]}
    end

    test "returns error when subject has no permission to create api tokens", %{subject: subject} do
      attrs = %{
        "expires_in" => 0
      }

      subject = SubjectFixtures.remove_permissions(subject)

      assert create_api_token(attrs, subject) ==
               {:error,
                {:unauthorized,
                 [missing_permissions: [Authorizer.manage_owned_api_tokens_permission()]]}}
    end
  end

  describe "api_token_expired?/1" do
    test "returns true when expired" do
      api_token =
        ApiTokensFixtures.create_api_token(%{"expires_in" => 1})
        |> ApiTokensFixtures.expire_api_token()

      assert api_token_expired?(api_token) == true
    end

    test "returns false when not expired" do
      api_token = ApiTokensFixtures.create_api_token(%{"expires_in" => 1})
      assert api_token_expired?(api_token) == false
    end
  end

  describe "delete_api_token_by_id/1" do
    test "deletes the api token that belongs to a subject user", %{user: user, subject: subject} do
      api_token = ApiTokensFixtures.create_api_token(user: user)

      assert {:ok, deleted_api_token} = delete_api_token_by_id(api_token.id, subject)

      assert deleted_api_token.id == api_token.id
      refute Repo.one(ApiToken)
    end

    test "deletes api token that belongs to another user with manage permission", %{
      subject: subject
    } do
      api_token = ApiTokensFixtures.create_api_token()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())
        |> SubjectFixtures.add_permission(Authorizer.manage_api_tokens_permission())

      assert {:ok, deleted_api_token} = delete_api_token_by_id(api_token.id, subject)

      assert deleted_api_token.id == api_token.id
      refute Repo.one(ApiToken)
    end

    test "does not delete api token that belongs to another user with manage_owned permission",
         %{
           subject: subject
         } do
      api_token = ApiTokensFixtures.create_api_token()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())
        |> SubjectFixtures.add_permission(Authorizer.manage_owned_api_tokens_permission())

      assert delete_api_token_by_id(api_token.id, subject) ==
               {:error, :not_found}
    end

    test "does not delete api token that belongs to another user with just view permission", %{
      subject: subject
    } do
      api_token = ApiTokensFixtures.create_api_token()

      subject =
        subject
        |> SubjectFixtures.remove_permissions()
        |> SubjectFixtures.add_permission(Authorizer.view_api_tokens_permission())

      assert delete_api_token_by_id(api_token.id, subject) ==
               {:error, :not_found}
    end

    test "returns error when api token does not exist", %{subject: subject} do
      assert delete_api_token_by_id(Ecto.UUID.generate(), subject) == {:error, :not_found}
    end

    test "returns error when subject can not view api tokens", %{subject: subject} do
      subject = SubjectFixtures.remove_permissions(subject)

      assert delete_api_token_by_id(Ecto.UUID.generate(), subject) ==
               {:error,
                {:unauthorized, [missing_permissions: [Authorizer.view_api_tokens_permission()]]}}
    end
  end
end
