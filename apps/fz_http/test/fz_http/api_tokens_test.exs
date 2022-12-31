defmodule FzHttp.ApiTokensTest do
  use FzHttp.DataCase

  alias FzHttp.ApiTokens

  describe "api_tokens" do
    alias FzHttp.ApiTokens.ApiToken

    import FzHttp.ApiTokensFixtures
    import FzHttp.UsersFixtures

    @invalid_params %{"expires_in" => 0}

    test "list_api_tokens/0 returns all api_tokens" do
      api_token = api_token()
      assert ApiTokens.list_api_tokens() == [api_token]
    end

    test "list_api_tokens/1 returns api_tokens scoped to a user" do
      api_token1 = api_token()
      api_token2 = api_token()
      assert [api_token1] == ApiTokens.list_api_tokens(api_token1.user_id)
      assert [api_token2] == ApiTokens.list_api_tokens(api_token2.user_id)
    end

    test "get_api_token!/1 returns the api_token with given id" do
      api_token = api_token()
      assert ApiTokens.get_api_token!(api_token.id) == api_token
    end

    test "create_user_api_token/2 with valid data creates a api_token" do
      valid_params = %{
        "expires_in" => 1
      }

      assert {:ok, %ApiToken{} = api_token} =
               ApiTokens.create_user_api_token(user(), valid_params)

      # Within 10 seconds
      assert_in_delta DateTime.to_unix(api_token.expires_at),
                      DateTime.to_unix(DateTime.add(DateTime.utc_now(), 1, :day)),
                      10
    end

    test "create_user_api_token/2 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} =
               ApiTokens.create_user_api_token(user(), @invalid_params)
    end
  end
end
