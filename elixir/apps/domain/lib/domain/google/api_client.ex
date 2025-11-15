defmodule Domain.Google.APIClient do
  def get_access_token(impersonation_email) do
    config = Domain.Config.fetch_env!(:domain, __MODULE__)
    token_endpoint = config[:token_endpoint]
    key = config[:service_account_key] |> JSON.decode!()
    iss = key["client_email"]
    private_key = key["private_key"]

    unix_timestamp = :os.system_time(:seconds)
    jws = %{"alg" => "RS256", "typ" => "JWT"}
    jwk = JOSE.JWK.from_pem(private_key)

    scope = ~w[
      https://www.googleapis.com/auth/admin.directory.customer.readonly
      https://www.googleapis.com/auth/admin.directory.orgunit.readonly
      https://www.googleapis.com/auth/admin.directory.group.readonly
      https://www.googleapis.com/auth/admin.directory.user.readonly
    ] |> Enum.join(" ")

    claim_set =
      %{
        "iss" => iss,
        "scope" => scope,
        "aud" => token_endpoint,
        "sub" => impersonation_email,
        "exp" => unix_timestamp + 3600,
        "iat" => unix_timestamp
      }
      |> JSON.encode!()

    jwt =
      JOSE.JWS.sign(jwk, claim_set, jws)
      |> JOSE.JWS.compact()
      |> elem(1)

    payload =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    Req.post(token_endpoint,
      headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
      body: payload
    )
  end

  def get_customer(access_token) do
    "/admin/directory/v1/customers/my_customer"
    |> get(access_token)
  end

  defp get(path, access_token) do
    config = Domain.Config.fetch_env!(:domain, __MODULE__)

    (config[:endpoint] <> path)
    |> Req.get(headers: [Authorization: "Bearer #{access_token}"])
  end
end
