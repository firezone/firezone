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
  end

  describe "verify/2 key cache" do
    test "resolves and caches the signing key on a miss" do
      account = account_fixture()

      token =
        FlowLogToken.mint(account, flow_log_token_claims(), expires_in(3600))

      assert {{:ok, _claims}, cache} = FlowLogToken.verify(token, %{})
      assert Map.fetch!(cache, account.id) == account.ingest_signing_key
    end

    test "verifies from the cache without touching the database" do
      # Never persisted: a DB lookup would resolve :not_found -> :invalid, so a
      # successful verify proves the cached key short-circuited the lookup.
      account = %Portal.Account{
        id: Ecto.UUID.generate(),
        ingest_signing_key: :crypto.strong_rand_bytes(32)
      }

      token = FlowLogToken.mint(account, flow_log_token_claims(), expires_in(3600))
      cache = %{account.id => account.ingest_signing_key}

      assert {{:ok, claims}, ^cache} = FlowLogToken.verify(token, cache)
      assert claims["account_id"] == account.id
    end
  end

  defp expires_in(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)
end
