defmodule Domain.Okta.APIClient do
  @moduledoc """
  API client for Okta directory sync operations.
  """
  require Logger

  @doc """
  Gets an access token using client credentials with private key JWT.

  This is used for directory sync verification and operations.
  """
  def get_access_token(okta_domain, client_id, private_key_jwk, kid) do
    # Create the JWT assertion
    jwt = create_jwt_assertion(okta_domain, client_id, private_key_jwk, kid)

    # Request access token from Okta
    token_url = "https://#{okta_domain}/oauth2/v1/token"

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    body =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "scope" => "okta.users.read okta.groups.read",
        "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion" => jwt
      })

    case Req.post(token_url, headers: headers, body: body) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Failed to get Okta access token", status: status, body: inspect(body))
        {:error, {status, body}}

      {:error, reason} ->
        Logger.error("Failed to connect to Okta", reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Makes a test API call to verify the access token works.
  """
  def test_connection(okta_domain, access_token) do
    url = "https://#{okta_domain}/api/v1/users?limit=1"
    headers = [{"Authorization", "Bearer #{access_token}"}]

    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Okta API test failed", status: status, body: inspect(body))
        {:error, {status, body}}

      {:error, reason} ->
        Logger.error("Failed to connect to Okta API", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp create_jwt_assertion(okta_domain, client_id, private_key_jwk, kid) do
    # JWT header
    header = %{
      "alg" => "RS256",
      "typ" => "JWT",
      "kid" => kid
    }

    # JWT payload
    now = System.system_time(:second)
    # 5 minutes
    exp = now + 300

    payload = %{
      "iss" => client_id,
      "sub" => client_id,
      "aud" => "https://#{okta_domain}/oauth2/v1/token",
      "iat" => now,
      "exp" => exp
    }

    # Sign the JWT
    jwk = JOSE.JWK.from_map(private_key_jwk)
    jws = JOSE.JWS.from_map(header)

    {_jws, jwt} = JOSE.JWT.sign(jwk, jws, payload)

    JOSE.JWS.compact(jwt) |> elem(1)
  end
end
