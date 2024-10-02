defmodule Domain.Tokens.Jobs.RefreshBrowserSessionTokensTest do
  use Domain.DataCase, async: true
  import Domain.Tokens.Jobs.RefreshBrowserSessionTokens

  describe "execute/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_openid_connect_provider(account: account)

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      %{
        bypass: bypass,
        account: account,
        provider: provider,
        identity: identity
      }
    end

    test "refreshes all active browser session tokens", %{
      bypass: bypass,
      account: account,
      provider: provider,
      identity: identity
    } do
      token =
        Fixtures.Tokens.create_token(
          account: account,
          provider: provider,
          identity: identity,
          expires_at: DateTime.utc_now() |> DateTime.add(3, :minute)
        )

      {id_token, _claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)

      Mocks.OpenIDConnect.expect_refresh_token(bypass, %{
        "token_type" => "Bearer",
        "id_token" => id_token,
        "access_token" => "MY_ACCESS_TOKEN",
        "refresh_token" => "MY_REFRESH_TOKEN",
        "expires_in" => 3600
      })

      Mocks.OpenIDConnect.expect_userinfo(bypass)

      assert execute(%{}) == :ok

      assert updated_identity = Repo.get(Domain.Auth.Identity, token.identity_id)

      assert %{
               "access_token" => "MY_ACCESS_TOKEN",
               "expires_at" => expires_at,
               "userinfo" => %{
                 "email" => "ada@example.com",
                 "email_verified" => true,
                 "family_name" => "Lovelace",
                 "given_name" => "Ada",
                 "locale" => "en",
                 "name" => "Ada Lovelace",
                 "picture" =>
                   "https://lh3.googleusercontent.com/-XdUIqdMkCWA/AAAAAAAAAAI/AAAAAAAAAAA/4252rscbv5M/photo.jpg",
                 "sub" => "353690423699814251281"
               }
             } = updated_identity.provider_state

      assert {:ok, expires_at, 0} = DateTime.from_iso8601(expires_at)
      expires_in = DateTime.diff(expires_at, DateTime.utc_now(), :second)
      assert expires_in > 3595
      assert expires_in < 3605

      assert updated_token = Repo.get(Domain.Tokens.Token, token.id)
      assert DateTime.compare(updated_token.expires_at, expires_at) == :eq
      assert updated_token.expires_at != token.expires_at
    end

    test "does not refresh session tokens when request returned an error", %{
      bypass: bypass,
      account: account,
      provider: provider,
      identity: identity
    } do
      token =
        Fixtures.Tokens.create_token(
          account: account,
          provider: provider,
          identity: identity,
          expires_at: DateTime.utc_now() |> DateTime.add(3, :minute)
        )

      Mocks.OpenIDConnect.expect_refresh_token_failure(bypass)

      assert execute(%{}) == :ok

      assert updated_identity = Repo.get(Domain.Auth.Identity, token.identity_id)
      assert updated_identity.provider_state == %{}

      assert fetched_token = Repo.get(Domain.Tokens.Token, token.id)
      assert fetched_token.expires_at == token.expires_at
    end

    test "does not refresh session tokens when request failed", %{
      bypass: bypass,
      account: account,
      provider: provider,
      identity: identity
    } do
      token =
        Fixtures.Tokens.create_token(
          account: account,
          provider: provider,
          identity: identity,
          expires_at: DateTime.utc_now() |> DateTime.add(3, :minute)
        )

      Bypass.down(bypass)

      assert execute(%{}) == :ok

      assert updated_identity = Repo.get(Domain.Auth.Identity, token.identity_id)
      assert updated_identity.provider_state == %{}

      assert fetched_token = Repo.get(Domain.Tokens.Token, token.id)
      assert fetched_token.expires_at == token.expires_at
    end

    test "does not refresh session tokens for providers that do not support it", %{
      account: account
    } do
      Domain.Config.put_env_override(:outbound_email_adapter_configured?, true)
      provider = Fixtures.Auth.create_email_provider(account: account)
      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      token =
        Fixtures.Tokens.create_token(
          account: account,
          provider: provider,
          identity: identity,
          expires_at: DateTime.utc_now() |> DateTime.add(3, :minute)
        )

      assert execute(%{}) == :ok

      assert updated_identity = Repo.get(Domain.Auth.Identity, token.identity_id)
      assert updated_identity.provider_state == %{}

      assert fetched_token = Repo.get(Domain.Tokens.Token, token.id)
      assert fetched_token.expires_at == token.expires_at
    end
  end
end
