defmodule FzHttp.ApiTokensTest do
  use FzHttp.DataCase

  alias FzHttp.ApiTokens

  describe "api_tokens" do
    alias FzHttp.ApiTokens.ApiToken

    import FzHttp.ApiTokensFixtures
    import FzHttp.UsersFixtures

    @invalid_attrs %{user_id: nil}

    test "list_api_tokens/0 returns all api_tokens" do
      api_token = api_token_fixture()
      assert ApiTokens.list_api_tokens() == [api_token]
    end

    test "get_api_token!/1 returns the api_token with given id" do
      api_token = api_token_fixture()
      assert ApiTokens.get_api_token!(api_token.id) == api_token
    end

    test "create_api_token/1 with valid data creates a api_token" do
      valid_attrs = %{
        user_id: user().id,
        revoked_at: ~U[2022-11-25 04:48:00.000000Z]
      }

      assert {:ok, %ApiToken{} = api_token} = ApiTokens.create_api_token(valid_attrs)
      assert api_token.revoked_at == ~U[2022-11-25 04:48:00.000000Z]
    end

    test "create_api_token/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = ApiTokens.create_api_token(@invalid_attrs)
    end

    test "update_api_token/2 with valid data updates the api_token" do
      api_token = api_token_fixture()
      update_attrs = %{revoked_at: ~U[2022-11-26 04:48:00.000000Z]}

      assert {:ok, %ApiToken{} = api_token} = ApiTokens.update_api_token(api_token, update_attrs)
      assert api_token.revoked_at == ~U[2022-11-26 04:48:00.000000Z]
    end

    test "update_api_token/2 with invalid data returns error changeset" do
      api_token = api_token_fixture()
      assert {:error, %Ecto.Changeset{}} = ApiTokens.update_api_token(api_token, @invalid_attrs)
      assert api_token == ApiTokens.get_api_token!(api_token.id)
    end

    test "delete_api_token/1 deletes the api_token" do
      api_token = api_token_fixture()
      assert {:ok, %ApiToken{}} = ApiTokens.delete_api_token(api_token)
      assert_raise Ecto.NoResultsError, fn -> ApiTokens.get_api_token!(api_token.id) end
    end

    test "change_api_token/1 returns a api_token changeset" do
      api_token = api_token_fixture()
      assert %Ecto.Changeset{} = ApiTokens.change_api_token(api_token)
    end
  end
end
