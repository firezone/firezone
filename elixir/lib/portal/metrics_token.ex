defmodule Portal.MetricsToken do
  @moduledoc """
  Mints and verifies the tokens gateways report metrics with.

  A token is an EdDSA (Ed25519) JWT signed with Firezone's metrics signing key
  and naming that key in its `kid` header. Verification derives the public key
  from the same configured private key, so rotating the key rejects tokens
  minted under the old `kid` until their gateways are sent fresh ones.

  The claims carry the full attribution of the reporting device: account,
  gateway and site, each with a human-readable name. Attribution travels in the
  token so the ingest endpoint can verify and attribute a report without
  touching the database.

  `exp` is one hour from minting. Revocation is by expiry: connected gateways
  are sent a fresh token well before theirs expires, so a gateway that loses
  its connection to the portal stops being able to report within the hour.
  The ingest endpoint is served by the portal, so a gateway that cannot reach
  the portal cannot report anyway.
  """
  alias Portal.Account
  alias Portal.Site

  @token_lifetime_seconds 3_600

  @doc """
  Mint a token attributing metrics reports to `gateway_id` in `account`.

  Errs when no signing key is configured, so that a deployment without one
  reports no metrics rather than failing to serve gateways.
  """
  @spec mint(Account.t(), Ecto.UUID.t(), Site.t()) ::
          {:ok, String.t()} | {:error, :no_signing_key}
  def mint(%Account{id: account_id, slug: account_slug}, gateway_id, %Site{
        id: site_id,
        name: site_name
      }) do
    issued_at = DateTime.to_unix(DateTime.utc_now())

    claims = %{
      "account_id" => account_id,
      "account_slug" => account_slug,
      "gateway_id" => gateway_id,
      "site_id" => site_id,
      "site_name" => site_name,
      "iat" => issued_at,
      "exp" => issued_at + @token_lifetime_seconds
    }

    with {:ok, signing_key} <- signing_key() do
      token =
        signing_key
        |> JOSE.JWT.sign(%{"alg" => "EdDSA", "kid" => key_id()}, claims)
        |> JOSE.JWS.compact()
        |> elem(1)

      {:ok, token}
    end
  end

  @doc """
  Verify a token and return its claims.

  The algorithm is pinned to EdDSA, so a token presenting another `alg`
  (including `none`) is rejected.
  """
  @spec verify(term()) :: {:ok, map()} | {:error, :invalid | :expired}
  def verify(token) when is_binary(token) do
    with {:ok, signing_key} <- signing_key(),
         %JOSE.JWS{fields: %{"kid" => kid}} when is_binary(kid) <- JOSE.JWT.peek_protected(token),
         true <- kid == key_id(),
         {true, %JOSE.JWT{fields: claims}, _jws} <-
           JOSE.JWT.verify_strict(JOSE.JWK.to_public(signing_key), ["EdDSA"], token) do
      verify_exp(claims)
    else
      _ -> {:error, :invalid}
    end
  rescue
    # `peek_protected` and `verify_strict` raise on input that is not a JWS.
    _ -> {:error, :invalid}
  end

  def verify(_token), do: {:error, :invalid}

  defp verify_exp(%{"exp" => exp} = claims) when is_integer(exp) do
    if DateTime.to_unix(DateTime.utc_now()) < exp do
      {:ok, claims}
    else
      {:error, :expired}
    end
  end

  defp verify_exp(_claims), do: {:error, :invalid}

  defp signing_key do
    case Portal.Config.fetch_env!(:portal, :metrics_token_private_key) do
      pem when is_binary(pem) and pem != "" -> {:ok, JOSE.JWK.from_pem(unescape_newlines(pem))}
      _unconfigured -> {:error, :no_signing_key}
    end
  end

  # The release reads its environment through `docker run --env-file`, which
  # cannot carry embedded newlines, so a deployed PEM arrives with them escaped.
  defp unescape_newlines(pem), do: String.replace(pem, "\\n", "\n")

  defp key_id, do: Portal.Config.fetch_env!(:portal, :metrics_token_key_id)
end
