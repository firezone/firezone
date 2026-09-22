defmodule Portal.MetricsToken do
  @moduledoc """
  Mints the tokens gateways report metrics with.

  A token is an EdDSA (Ed25519) JWT signed with Firezone's metrics signing key.
  The `kid` header names the key so keys can be rotated with overlapping
  validity: the ingest service keeps every currently valid public key and picks
  the one the token names.

  The claims carry the full attribution of the reporting device: account,
  gateway and site, each with the human-readable name the ingest service turns
  into a metric label. Attribution travels in the token so the ingest service
  never has to reach into the portal's database.

  The portal does not verify these tokens; the ingest service does, which is why
  the key is asymmetric.

  `exp` is 7 days from minting. The exporter keeps reporting while its websocket
  to the portal is down, so the token has to outlive a disconnect; a gateway
  that reconnects is issued a fresh token on every `init`, so the window never
  has to cover more than one outage.
  """
  alias Portal.Account
  alias Portal.Site

  @token_lifetime_seconds 604_800

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

  defp signing_key do
    case Portal.Config.fetch_env!(:portal, :metrics_token_private_key) do
      pem when is_binary(pem) and pem != "" -> {:ok, JOSE.JWK.from_pem(pem)}
      _unconfigured -> {:error, :no_signing_key}
    end
  end

  defp key_id, do: Portal.Config.fetch_env!(:portal, :metrics_token_key_id)
end
