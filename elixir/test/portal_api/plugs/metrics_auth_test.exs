defmodule PortalAPI.Plugs.MetricsAuthTest do
  use PortalAPI.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.RepoQueryHelpers
  import Portal.SiteFixtures

  alias PortalAPI.Plugs.MetricsAuth

  setup do
    account = account_fixture()
    site = site_fixture(account: account)
    {:ok, token} = Portal.MetricsToken.mint(account, Ecto.UUID.generate(), site)

    %{account: account, site: site, token: token}
  end

  defp call(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> MetricsAuth.call(MetricsAuth.init([]))
  end

  defp signing_key do
    Portal.Config.fetch_env!(:portal, :metrics_token_private_key) |> JOSE.JWK.from_pem()
  end

  defp claims(token), do: JOSE.JWT.peek_payload(token).fields

  defp sign(jwk, header, claims) do
    jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact() |> elem(1)
  end

  defp assert_rejected(conn) do
    assert conn.halted
    assert conn.status == 401
  end

  test "accepts a token it minted and assigns its claims", %{conn: conn, token: token} do
    conn = call(conn, token)

    refute conn.halted
    assert conn.assigns.metrics_claims == claims(token)
  end

  test "verifies without touching the database", %{conn: conn, token: token} do
    assert capture_queries_on_all_repos(fn -> call(conn, token) end) == []
  end

  test "rejects a request without a token", %{conn: conn} do
    conn |> MetricsAuth.call(MetricsAuth.init([])) |> assert_rejected()
  end

  test "rejects a token signed with another key", %{conn: conn, token: token} do
    other_key = JOSE.JWK.generate_key({:okp, :Ed25519})
    forged = sign(other_key, %{"alg" => "EdDSA", "kid" => "dev"}, claims(token))

    conn |> call(forged) |> assert_rejected()
  end

  test "rejects a token whose payload was tampered with", %{conn: conn, token: token} do
    [header, _payload, signature] = String.split(token, ".")

    payload =
      token
      |> claims()
      |> Map.put("account_id", Ecto.UUID.generate())
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    conn |> call(Enum.join([header, payload, signature], ".")) |> assert_rejected()
  end

  test "rejects an unsigned token", %{conn: conn, token: token} do
    encode = &(&1 |> JSON.encode!() |> Base.url_encode64(padding: false))
    unsigned = encode.(%{"alg" => "none", "kid" => "dev"}) <> "." <> encode.(claims(token)) <> "."

    conn |> call(unsigned) |> assert_rejected()
  end

  test "rejects a token signed with another algorithm", %{conn: conn, token: token} do
    hmac = sign(JOSE.JWK.from_oct("secret"), %{"alg" => "HS256", "kid" => "dev"}, claims(token))

    conn |> call(hmac) |> assert_rejected()
  end

  test "rejects a token naming another key", %{conn: conn, token: token} do
    other_kid = sign(signing_key(), %{"alg" => "EdDSA", "kid" => "retired"}, claims(token))

    conn |> call(other_kid) |> assert_rejected()
  end

  test "rejects an expired token", %{conn: conn, token: token} do
    expired =
      sign(
        signing_key(),
        %{"alg" => "EdDSA", "kid" => "dev"},
        Map.put(claims(token), "exp", System.system_time(:second) - 1)
      )

    conn |> call(expired) |> assert_rejected()
  end

  test "rejects a token that is not a JWT", %{conn: conn} do
    conn |> call("not-a-jwt") |> assert_rejected()
  end
end
