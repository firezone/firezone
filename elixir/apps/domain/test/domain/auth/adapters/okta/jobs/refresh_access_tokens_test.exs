defmodule Domain.Auth.Adapters.Okta.Jobs.RefreshAccessTokensTest do
  use Domain.DataCase, async: true
  import Domain.Auth.Adapters.Okta.Jobs.RefreshAccessTokens

  describe "execute/1" do
    setup do
      account = Fixtures.Accounts.create_account()

      {provider, bypass} =
        Fixtures.Auth.start_and_create_okta_provider(account: account)

      provider =
        Domain.Fixture.update!(provider, %{
          adapter_state: %{
            "access_token" => "OIDC_ACCESS_TOKEN",
            "refresh_token" => "OIDC_REFRESH_TOKEN",
            "expires_at" => DateTime.utc_now() |> DateTime.add(15, :minute),
            "claims" => "openid email profile offline_access"
          }
        })

      identity = Fixtures.Auth.create_identity(account: account, provider: provider)

      %{
        bypass: bypass,
        account: account,
        provider: provider,
        identity: identity
      }
    end

    test "refreshes the access token", %{
      provider: provider,
      identity: identity,
      bypass: bypass
    } do
      {token, claims} = Mocks.OpenIDConnect.generate_openid_connect_token(provider, identity)

      bypass
      |> Mocks.OpenIDConnect.expect_refresh_token(%{
        "token_type" => "Bearer",
        "id_token" => token,
        "access_token" => "MY_ACCESS_TOKEN",
        "refresh_token" => "OTHER_REFRESH_TOKEN",
        "expires_in" => nil
      })
      |> Mocks.OpenIDConnect.expect_userinfo()

      assert execute(%{}) == :ok

      provider = Repo.get!(Domain.Auth.Provider, provider.id)

      assert %{
               "access_token" => "MY_ACCESS_TOKEN",
               "claims" => ^claims,
               "expires_at" => expires_at,
               "refresh_token" => "OIDC_REFRESH_TOKEN",
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
             } = provider.adapter_state

      assert expires_at
    end

    test "does not crash when endpoint is not available", %{
      bypass: bypass
    } do
      Bypass.down(bypass)
      assert execute(%{}) == :ok
    end
  end
end
