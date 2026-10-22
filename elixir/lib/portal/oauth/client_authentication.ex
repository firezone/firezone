defmodule Portal.OAuth.ClientAuthentication do
  @moduledoc """
  Authenticates token requests using the method selected from CIMD metadata.

  Signed clients cannot fall back to the public-client flow. Assertions are
  verified only against keys fetched from the registered JWKS URL, never a URL
  or key supplied in the assertion. Replay protection is shared by all nodes.
  """

  alias Portal.OAuth
  alias Portal.OAuth.ClientMetadata
  alias __MODULE__.Database

  @assertion_type "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
  @max_lifetime 300
  @replay_retention_seconds 60

  def authenticate(params, client_id, endpoint \\ :token)

  def authenticate(%{"client_secret" => _}, _client_id, _endpoint), do: invalid_client()

  def authenticate(params, client_id, endpoint) when endpoint in [:token, :revoke] do
    case OAuth.cached_client(client_id) do
      %{token_endpoint_auth_method: "none"} ->
        if Map.has_key?(params, "client_assertion") or
             Map.has_key?(params, "client_assertion_type") do
          invalid_client()
        else
          :ok
        end

      %{token_endpoint_auth_method: "private_key_jwt"} = client ->
        authenticate_assertion(params, client, endpoint)

      _ ->
        invalid_client()
    end
  end

  defp authenticate_assertion(params, client, endpoint) do
    with %{"client_assertion_type" => @assertion_type, "client_assertion" => assertion}
         when is_binary(assertion) and byte_size(assertion) <= 8192 <- params,
         {:ok, kid} <- assertion_key_id(assertion),
         {:ok, keys} <- ClientMetadata.fetch_jwks(client.jwks_uri),
         [key] <- Enum.filter(keys, &(is_map(&1) and &1["kid"] == kid)),
         true <- signing_key?(key),
         {:ok, claims} <- verify(assertion, key),
         :ok <- validate_claims(claims, client.client_id, endpoint),
         :ok <-
           Database.consume_assertion(
             client.client_id,
             claims["jti"],
             claims["exp"] + @replay_retention_seconds
           ) do
      :ok
    else
      _ -> invalid_client()
    end
  end

  defp assertion_key_id(assertion) do
    with [header, _, _] <- String.split(assertion, "."),
         {:ok, decoded} <- Base.url_decode64(header, padding: false),
         {:ok, %{"alg" => "RS256", "kid" => kid} = fields} <- Jason.decode(decoded),
         true <- is_binary(kid) and byte_size(kid) in 1..256,
         false <- Map.has_key?(fields, "crit"),
         false <- Map.has_key?(fields, "b64") do
      {:ok, kid}
    else
      _ -> :error
    end
  end

  defp signing_key?(%{"kty" => "RSA", "n" => n, "e" => e} = key)
       when is_binary(n) and is_binary(e) do
    with {:ok, modulus} <- Base.url_decode64(n, padding: false),
         true <- byte_size(modulus) in 256..1024 and :binary.first(modulus) >= 128,
         {:ok, exponent} <- Base.url_decode64(e, padding: false),
         true <- byte_size(exponent) in 1..8,
         exponent_value = :binary.decode_unsigned(exponent),
         true <- exponent_value >= 3 and rem(exponent_value, 2) == 1 do
      key["use"] in [nil, "sig"] and key["alg"] in [nil, "RS256"] and
        (is_nil(key["key_ops"]) or key["key_ops"] == ["verify"]) and
        not Enum.any?(~w[d p q dp dq qi oth], &Map.has_key?(key, &1))
    else
      _ -> false
    end
  end

  defp signing_key?(_), do: false

  defp verify(assertion, key) do
    case JOSE.JWT.verify_strict(JOSE.JWK.from_map(key), ["RS256"], assertion) do
      {true, %JOSE.JWT{fields: claims}, _} -> {:ok, claims}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp validate_claims(claims, client_id, endpoint) do
    now = System.system_time(:second)
    issuer = PortalWeb.Endpoint.url()
    audiences = [issuer, issuer <> "/oauth/#{endpoint}"]

    with %{"iss" => ^client_id, "sub" => ^client_id, "exp" => exp, "iat" => iat, "jti" => jti}
         when is_integer(exp) and is_integer(iat) and is_binary(jti) <- claims,
         true <- byte_size(jti) in 1..256,
         true <- exp > now and exp <= now + @max_lifetime and exp - iat <= @max_lifetime,
         true <- iat <= now + 30 and iat >= now - @max_lifetime and exp > iat,
         true <- valid_not_before?(claims["nbf"], now),
         true <- valid_audience?(claims["aud"], audiences) do
      :ok
    else
      _ -> :error
    end
  end

  defp valid_not_before?(nil, _now), do: true
  defp valid_not_before?(nbf, now), do: is_integer(nbf) and nbf <= now

  defp valid_audience?(aud, audiences) when is_binary(aud), do: aud in audiences

  defp valid_audience?(aud, audiences) when is_list(aud),
    do: Enum.all?(aud, &is_binary/1) and Enum.any?(aud, &(&1 in audiences))

  defp valid_audience?(_, _), do: false

  defp invalid_client, do: {:error, "invalid_client", "Client authentication failed."}

  defmodule Database do
    @moduledoc false
    import Ecto.Query
    alias Portal.Safe

    def consume_assertion(client_id, jti, exp) do
      now = DateTime.utc_now()

      from(a in "oauth_client_assertions", where: a.expires_at <= type(^now, :utc_datetime_usec))
      |> Safe.unscoped()
      |> Safe.delete_all()

      id = :crypto.hash(:sha256, :erlang.term_to_binary({client_id, jti}))
      # Keep records past assertion expiry so clock skew cannot reopen replay
      # on a slower node after a faster node has cleaned up.
      expires_at = DateTime.from_unix!(exp)

      Safe.unscoped()
      |> Safe.insert_all("oauth_client_assertions", [%{id: id, expires_at: expires_at}],
        on_conflict: :nothing
      )
      |> case do
        {1, _} -> :ok
        _ -> :error
      end
    end
  end
end
