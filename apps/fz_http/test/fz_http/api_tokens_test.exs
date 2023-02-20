defmodule FzHttp.ApiTokensTest do
  use FzHttp.DataCase, async: true
  alias FzHttp.ApiTokensFixtures
  alias FzHttp.UsersFixtures
  alias FzHttp.ApiTokens
  alias FzHttp.ApiTokens.ApiToken

  describe "count_by_user_id/1" do
    test "returns 0 when no user exist" do
      assert ApiTokens.count_by_user_id(Ecto.UUID.generate()) == 0
    end

    test "returns the number of api_tokens for a user" do
      user = UsersFixtures.create_user()
      assert ApiTokens.count_by_user_id(user.id) == 0

      ApiTokensFixtures.create_api_token(user: user)
      assert ApiTokens.count_by_user_id(user.id) == 1

      ApiTokensFixtures.create_api_token(user: user)
      assert ApiTokens.count_by_user_id(user.id) == 2
    end
  end

  describe "list_api_tokens/0" do
    test "returns empty list when no api tokens" do
      assert ApiTokens.list_api_tokens() == {:ok, []}
    end

    test "returns all api_tokens" do
      assert ApiTokens.list_api_tokens() == {:ok, []}

      api_token = ApiTokensFixtures.create_api_token()
      assert ApiTokens.list_api_tokens() == {:ok, [api_token]}
    end
  end

  describe "list_api_tokens_by_user_id/1" do
    test "returns api tokens scoped to a user" do
      api_token1 = ApiTokensFixtures.create_api_token()
      api_token2 = ApiTokensFixtures.create_api_token()

      assert ApiTokens.list_api_tokens_by_user_id(api_token1.user_id) == {:ok, [api_token1]}
      assert ApiTokens.list_api_tokens_by_user_id(api_token2.user_id) == {:ok, [api_token2]}
    end
  end

  describe "fetch_api_token_by_id/1" do
    test "returns error when UUID is invalid" do
      assert ApiTokens.fetch_api_token_by_id("foo") == {:error, :not_found}
    end

    test "returns api token by id" do
      api_token = ApiTokensFixtures.create_api_token()
      assert ApiTokens.fetch_api_token_by_id(api_token.id) == {:ok, api_token}
    end
  end

  describe "fetch_unexpired_api_token_by_id/1" do
    test "fetches the unexpired token" do
      api_token = ApiTokensFixtures.create_api_token()
      assert ApiTokens.fetch_unexpired_api_token_by_id(api_token.id) == {:ok, api_token}
    end

    test "returns error for expired token" do
      api_token =
        ApiTokensFixtures.create_api_token(%{"expires_in" => 1})
        |> ApiTokensFixtures.expire_api_token()

      assert ApiTokens.fetch_unexpired_api_token_by_id(api_token.id) == {:error, :not_found}
    end
  end

  describe "create_user_api_token/2" do
    test "creates an api_token" do
      user = UsersFixtures.create_user()

      valid_params = %{
        "expires_in" => 1
      }

      assert {:ok, %ApiToken{} = api_token} = ApiTokens.create_user_api_token(user, valid_params)

      # Within 10 seconds
      assert_in_delta DateTime.to_unix(api_token.expires_at),
                      DateTime.to_unix(DateTime.add(DateTime.utc_now(), 1, :day)),
                      10

      assert api_token.user_id == user.id
      assert api_token.expires_in == 1
    end

    test "returns changeset error on invalid data" do
      user = UsersFixtures.create_user()

      assert {:error, %Ecto.Changeset{} = changeset} =
               ApiTokens.create_user_api_token(user, %{"expires_in" => 0})

      assert changeset.valid? == false
      assert errors_on(changeset) == %{expires_in: ["must be greater than or equal to 1"]}
    end
  end

  describe "api_token_expired?/1" do
    test "returns true when expired" do
      api_token =
        ApiTokensFixtures.create_api_token(%{"expires_in" => 1})
        |> ApiTokensFixtures.expire_api_token()

      assert ApiTokens.api_token_expired?(api_token) == true
    end

    test "returns false when not expired" do
      api_token = ApiTokensFixtures.create_api_token(%{"expires_in" => 1})
      assert ApiTokens.api_token_expired?(api_token) == false
    end
  end

  describe "delete_api_token_by_id/1" do
    test "deletes the api token" do
      user = UsersFixtures.create_user()
      api_token = ApiTokensFixtures.create_api_token(user: user)

      assert {:ok, deleted_api_token} = ApiTokens.delete_api_token_by_id(api_token.id, user)

      assert deleted_api_token.id == api_token.id
      refute Repo.one(ApiTokens.ApiToken)
    end

    test "returns error when api token did not belong to user" do
      user = UsersFixtures.create_user()
      api_token = ApiTokensFixtures.create_api_token()

      assert ApiTokens.delete_api_token_by_id(api_token.id, user) == {:error, :not_found}
    end

    test "returns error when api token does not exist" do
      user = UsersFixtures.create_user()
      assert ApiTokens.delete_api_token_by_id(Ecto.UUID.generate(), user) == {:error, :not_found}
    end
  end
end
