defmodule Portal.MetricsTokenTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.SiteFixtures

  alias Portal.MetricsToken

  @public_key_pem """
  -----BEGIN PUBLIC KEY-----
  MCowBQYDK2VwAyEA+c0qSLTrAWZ1bJG2CEjLwys12haCmpjhnQLkucVQZxA=
  -----END PUBLIC KEY-----
  """

  setup do
    account = account_fixture()

    %{
      account: account,
      site: site_fixture(account: account),
      gateway_id: Ecto.UUID.generate()
    }
  end

  defp verify(token) do
    @public_key_pem
    |> JOSE.JWK.from_pem()
    |> JOSE.JWT.verify_strict(["EdDSA"], token)
  end

  describe "mint/3" do
    test "signs with EdDSA and names the configured key", %{
      account: account,
      site: site,
      gateway_id: gateway_id
    } do
      Portal.Config.put_env_override(:portal, :metrics_token_key_id, "2026-09")

      {:ok, token} = MetricsToken.mint(account, gateway_id, site)

      assert %JOSE.JWS{alg: {:jose_jws_alg_eddsa, :EdDSA}, fields: fields} =
               JOSE.JWT.peek_protected(token)

      assert fields["kid"] == "2026-09"
    end

    test "carries the attribution the ingest service needs", %{
      account: account,
      site: site,
      gateway_id: gateway_id
    } do
      {:ok, token} = MetricsToken.mint(account, gateway_id, site)

      assert {true, %JOSE.JWT{fields: claims}, _jws} = verify(token)

      assert claims["account_id"] == account.id
      assert claims["account_slug"] == account.slug
      assert claims["gateway_id"] == gateway_id
      assert claims["site_id"] == site.id
      assert claims["site_name"] == site.name

      assert Map.keys(claims) |> Enum.sort() ==
               ~w[account_id account_slug exp gateway_id iat site_id site_name]
    end

    test "stamps exp 7 days after minting", %{
      account: account,
      site: site,
      gateway_id: gateway_id
    } do
      {:ok, token} = MetricsToken.mint(account, gateway_id, site)

      assert {true, %JOSE.JWT{fields: claims}, _jws} = verify(token)
      assert claims["exp"] == claims["iat"] + 604_800
    end

    test "errs when no signing key is configured", %{
      account: account,
      site: site,
      gateway_id: gateway_id
    } do
      Portal.Config.put_env_override(:portal, :metrics_token_private_key, "")

      assert MetricsToken.mint(account, gateway_id, site) == {:error, :no_signing_key}
    end

    test "accepts a PEM whose newlines arrived escaped", %{
      account: account,
      site: site,
      gateway_id: gateway_id
    } do
      escaped =
        Portal.Config.fetch_env!(:portal, :metrics_token_private_key)
        |> String.replace("\n", "\\n")

      Portal.Config.put_env_override(:portal, :metrics_token_private_key, escaped)

      {:ok, token} = MetricsToken.mint(account, gateway_id, site)

      assert {true, _jwt, _jws} = verify(token)
    end

    test "does not verify against another key", %{
      account: account,
      site: site,
      gateway_id: gateway_id
    } do
      {:ok, token} = MetricsToken.mint(account, gateway_id, site)

      {_, other_public_key} = JOSE.JWK.generate_key({:okp, :Ed25519}) |> JOSE.JWK.to_public_map()

      assert {false, _jwt, _jws} =
               JOSE.JWK.from_map(other_public_key)
               |> JOSE.JWT.verify_strict(["EdDSA"], token)
    end
  end
end
