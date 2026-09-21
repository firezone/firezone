defmodule Portal.MetricsTokenTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  alias Portal.MetricsToken

  describe "mint/3 and verify/1" do
    setup do
      %{account: account_fixture(), gateway_id: Ecto.UUID.generate(), site_id: Ecto.UUID.generate()}
    end

    test "round-trips the attribution claims", %{
      account: account,
      gateway_id: gateway_id,
      site_id: site_id
    } do
      token = MetricsToken.mint(account, gateway_id, site_id)

      assert {:ok, claims} = MetricsToken.verify(token)
      assert claims["account_id"] == account.id
      assert claims["gateway_id"] == gateway_id
      assert claims["site_id"] == site_id
    end

    test "stamps exp 7 days after minting", %{
      account: account,
      gateway_id: gateway_id,
      site_id: site_id
    } do
      token = MetricsToken.mint(account, gateway_id, site_id)

      assert {:ok, claims} = MetricsToken.verify(token)
      assert claims["exp"] == claims["iat"] + 604_800
    end

    test "rejects a token signed with the wrong key", %{
      account: account,
      gateway_id: gateway_id,
      site_id: site_id
    } do
      impostor = %{account | ingest_signing_key: :crypto.strong_rand_bytes(32)}

      token = MetricsToken.mint(impostor, gateway_id, site_id)

      assert {:error, :invalid} = MetricsToken.verify(token)
    end

    test "rejects a tampered token", %{
      account: account,
      gateway_id: gateway_id,
      site_id: site_id
    } do
      token = MetricsToken.mint(account, gateway_id, site_id)

      assert {:error, :invalid} = MetricsToken.verify(token <> "x")
    end
  end

  describe "verify/1 edge cases" do
    test "rejects an unknown account" do
      account = %Portal.Account{
        id: Ecto.UUID.generate(),
        ingest_signing_key: :crypto.strong_rand_bytes(32)
      }

      token = MetricsToken.mint(account, Ecto.UUID.generate(), Ecto.UUID.generate())

      assert {:error, :invalid} = MetricsToken.verify(token)
    end

    test "rejects an expired token" do
      account = account_fixture()

      expired =
        account.ingest_signing_key
        |> JOSE.JWK.from_oct()
        |> JOSE.JWT.sign(%{"alg" => "HS256"}, %{
          "account_id" => account.id,
          "gateway_id" => Ecto.UUID.generate(),
          "site_id" => Ecto.UUID.generate(),
          "exp" => DateTime.to_unix(DateTime.utc_now()) - 1
        })
        |> JOSE.JWS.compact()
        |> elem(1)

      assert {:error, :expired} = MetricsToken.verify(expired)
    end

    test "rejects a malformed token" do
      assert {:error, :malformed} = MetricsToken.verify("not-a-jwt")
      assert {:error, :malformed} = MetricsToken.verify(nil)
      assert {:error, :malformed} = MetricsToken.verify(123)
    end

    test "rejects a token presenting a different algorithm" do
      account = account_fixture()

      forged =
        account.ingest_signing_key
        |> JOSE.JWK.from_oct()
        |> JOSE.JWT.sign(%{"alg" => "HS512"}, %{
          "account_id" => account.id,
          "exp" => 9_999_999_999
        })
        |> JOSE.JWS.compact()
        |> elem(1)

      assert {:error, :invalid} = MetricsToken.verify(forged)
    end
  end
end
