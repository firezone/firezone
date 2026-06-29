defmodule Portal.FlowLogTokenTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.FlowLogFixtures
  alias Portal.FlowLogToken

  describe "mint/3 and verify/1" do
    setup do
      %{account: account_fixture()}
    end

    test "round-trips the attribution claims", %{account: account} do
      attrs = flow_log_token_claims()
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      token = FlowLogToken.mint(account, attrs, expires_at)

      assert {:ok, claims} = FlowLogToken.verify(token)
      assert claims["account_id"] == account.id

      for {k, v} <- attrs do
        assert claims[k] == v
      end
    end

    test "stamps exp as the authorization expiry plus a 30 day grace window", %{account: account} do
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      token = FlowLogToken.mint(account, flow_log_token_claims(), expires_at)

      assert {:ok, claims} = FlowLogToken.verify(token)
      assert claims["exp"] == DateTime.to_unix(expires_at) + 2_592_000
    end

    test "only the known attribution claims are signed", %{account: account} do
      token =
        FlowLogToken.mint(
          account,
          flow_log_token_claims(%{"injected" => "nope"}),
          DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      assert {:ok, claims} = FlowLogToken.verify(token)
      refute Map.has_key?(claims, "injected")
    end

    test "rejects an expired token", %{account: account} do
      token =
        FlowLogToken.mint(
          account,
          flow_log_token_claims(),
          DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
        )

      assert {:error, :expired} = FlowLogToken.verify(token)
    end

    test "rejects a token signed with the wrong key", %{account: account} do
      impostor = %{account | ingest_signing_key: :crypto.strong_rand_bytes(32)}

      token =
        FlowLogToken.mint(impostor, flow_log_token_claims(), DateTime.add(DateTime.utc_now(), 3600, :second))

      assert {:error, :invalid} = FlowLogToken.verify(token)
    end

    test "rejects a tampered token", %{account: account} do
      token =
        FlowLogToken.mint(account, flow_log_token_claims(), DateTime.add(DateTime.utc_now(), 3600, :second))

      assert {:error, :invalid} = FlowLogToken.verify(token <> "x")
    end
  end

  describe "verify/1 edge cases" do
    test "rejects an unknown account" do
      account = %Portal.Account{
        id: Ecto.UUID.generate(),
        ingest_signing_key: :crypto.strong_rand_bytes(32)
      }

      token =
        FlowLogToken.mint(account, flow_log_token_claims(), DateTime.add(DateTime.utc_now(), 3600, :second))

      assert {:error, :invalid} = FlowLogToken.verify(token)
    end

    test "rejects a malformed token" do
      assert {:error, :malformed} = FlowLogToken.verify("not-a-jwt")
      assert {:error, :malformed} = FlowLogToken.verify(nil)
      assert {:error, :malformed} = FlowLogToken.verify(123)
    end

    test "rejects a token presenting a different algorithm" do
      account = account_fixture()

      forged =
        account.ingest_signing_key
        |> JOSE.JWK.from_oct()
        |> JOSE.JWT.sign(%{"alg" => "HS512"}, %{"account_id" => account.id, "exp" => 9_999_999_999})
        |> JOSE.JWS.compact()
        |> elem(1)

      assert {:error, :invalid} = FlowLogToken.verify(forged)
    end
  end
end
