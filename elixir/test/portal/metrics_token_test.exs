defmodule Portal.MetricsTokenTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  alias Portal.{Device, MetricsToken}

  @client %Device{type: :client, last_seen_version: "1.5.2"}
  @gateway %Device{type: :gateway, last_seen_version: nil}

  setup do
    salt =
      Repo.one!(from(s in "metrics_token_signing_salts", order_by: [desc: s.id], limit: 1, select: s.salt))

    secret_key_base =
      Application.fetch_env!(:portal, PortalWeb.Endpoint) |> Keyword.fetch!(:secret_key_base)

    key = :crypto.mac(:hmac, :sha256, secret_key_base, salt)

    %{account: account_fixture(), key: key}
  end

  describe "mint/2 and verify/1" do
    test "round-trips the account identity and allowed metrics", %{account: account} do
      token = MetricsToken.mint(account, @client, ["a", "b"])

      assert {:ok, claims} = MetricsToken.verify(token)
      assert claims["account_id"] == account.id
      assert claims["account_slug"] == account.slug
      assert claims["device_type"] == "client"
      assert claims["device_version"] == "1.5.2"
      assert claims["metrics"] == ["a", "b"]
      assert claims["exp"] - claims["iat"] == MetricsToken.ttl_seconds()
    end

    test "rejects an expired token", %{account: account, key: key} do
      token = sign(key, claims(account, %{"exp" => unix_now() - 1}))

      assert {:error, :expired} = MetricsToken.verify(token)
    end

    test "rejects a token signed with another key", %{account: account} do
      forged = sign(:crypto.strong_rand_bytes(32), claims(account))

      assert {:error, :invalid} = MetricsToken.verify(forged)
    end

    test "rejects a token presenting a different algorithm", %{account: account, key: key} do
      forged = sign(key, claims(account), "HS512")

      assert {:error, :invalid} = MetricsToken.verify(forged)
    end

    test "rejects a malformed token" do
      assert {:error, :invalid} = MetricsToken.verify("not-a-jwt")
      assert {:error, :malformed} = MetricsToken.verify(nil)
    end
  end

  describe "metrics claim" do
    test "matches metric names against patterns", %{account: account} do
      {:ok, claims} =
        account
        |> MetricsToken.mint(@gateway, ["connlib.*", "tunnel.error", "*.duration", "a*b*c"])
        |> MetricsToken.verify()

      for name <- ["connlib.network.packets", "connlib.", "tunnel.error", "dns.duration", "abc", "aXbYc"] do
        assert MetricsToken.allows?(claims, name), name
      end

      for name <- ["tunnel.errors", "connlib", "duration", "acb", "abcd"] do
        refute MetricsToken.allows?(claims, name), name
      end
    end

    test "* allows every metric", %{account: account} do
      {:ok, claims} = account |> MetricsToken.mint(@gateway, ["*"]) |> MetricsToken.verify()

      refute Map.has_key?(claims, "device_version")

      assert MetricsToken.allows?(claims, "anything")
    end

    test "an empty list allows nothing", %{account: account} do
      {:ok, claims} = account |> MetricsToken.mint(@gateway, []) |> MetricsToken.verify()

      refute MetricsToken.allows?(claims, "connlib.network.packets")
    end

    test "rejects any other shape", %{account: account, key: key} do
      for metrics <- [nil, "*", %{}, %{"all" => true}, [1], ["a", nil]] do
        token = sign(key, claims(account, %{"metrics" => metrics}))

        assert {:error, :malformed} = MetricsToken.verify(token), inspect(metrics)
      end

      token = sign(key, Map.delete(claims(account), "metrics"))
      assert {:error, :malformed} = MetricsToken.verify(token)
    end

    test "rejects an unknown or missing device type and a non-string version", %{account: account, key: key} do
      for overrides <- [%{"device_type" => "relay"}, %{"device_version" => 1}] do
        token = sign(key, claims(account, overrides))
        assert {:error, :malformed} = MetricsToken.verify(token), inspect(overrides)
      end

      token = sign(key, Map.delete(claims(account), "device_type"))
      assert {:error, :malformed} = MetricsToken.verify(token)
    end
  end

  defp claims(account, overrides \\ %{}) do
    Map.merge(
      %{
        "account_id" => account.id,
        "account_slug" => account.slug,
        "device_type" => "client",
        "device_version" => "1.5.2",
        "metrics" => ["*"],
        "exp" => unix_now() + 60
      },
      overrides
    )
  end

  defp sign(key, claims, alg \\ "HS256") do
    key
    |> JOSE.JWK.from_oct()
    |> JOSE.JWT.sign(%{"alg" => alg}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp unix_now, do: DateTime.utc_now() |> DateTime.to_unix()
end
