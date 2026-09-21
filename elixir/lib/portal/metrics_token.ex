defmodule Portal.MetricsToken do
  @moduledoc """
  Mints and verifies the tokens gateways report metrics with.

  A token is a standard HS256 JWT signed with the reporting account's symmetric
  `ingest_signing_key`. It carries the attribution that identifies the reporting
  device: the account, the gateway, and the site the gateway belongs to. It is
  the sole authenticator for `POST /v1/metrics`: it is sent in the
  `Authorization: Bearer` header of every OTLP export, so every data point in a
  request is attributed to the single gateway the token names.

  The accepted algorithm is pinned to HS256 on verify (`verify_strict`), so a
  token presenting another `alg` (including `none`) is rejected and there is no
  algorithm-confusion surface.

  `exp` is 7 days from minting. The exporter keeps reporting while its websocket
  to the portal is down, so the token has to outlive a disconnect; a gateway
  that reconnects is issued a fresh token on every `init`, so the window never
  has to cover more than one outage.
  """
  alias Portal.Account
  alias __MODULE__.Database

  @token_lifetime_seconds 604_800

  @type claims :: %{optional(String.t()) => term()}

  @doc """
  Mint a token attributing metrics reports to `gateway_id` in `account`.
  """
  @spec mint(Account.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def mint(%Account{ingest_signing_key: key, id: account_id}, gateway_id, site_id) do
    issued_at = DateTime.to_unix(DateTime.utc_now())

    claims = %{
      "account_id" => account_id,
      "gateway_id" => gateway_id,
      "site_id" => site_id,
      "iat" => issued_at,
      "exp" => issued_at + @token_lifetime_seconds
    }

    key
    |> jwk()
    |> JOSE.JWT.sign(%{"alg" => "HS256"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  @doc """
  Verify a token and return its claims.

  The endpoint is not pre-authenticated, so verification first decodes the
  (unverified) payload to read the `account_id` claim, loads the signing key,
  then verifies the signature with that key, pinning the algorithm to HS256, and
  finally checks `exp`.

  An unknown account and a bad signature both collapse to `:invalid` so the
  endpoint is not an oracle for which account ids exist.
  """
  @spec verify(term()) :: {:ok, claims()} | {:error, :malformed | :invalid | :expired}
  def verify(token) when is_binary(token) do
    with {:ok, account_id} <- peek_account_id(token),
         %Account{ingest_signing_key: key} <- fetch_account(account_id),
         {true, %JOSE.JWT{fields: claims}, _jws} <-
           JOSE.JWT.verify_strict(jwk(key), ["HS256"], token) do
      verify_exp(claims)
    else
      {:error, :malformed} -> {:error, :malformed}
      _ -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :malformed}

  defp jwk(key), do: JOSE.JWK.from_oct(key)

  # Reads the account_id from the unverified payload to pick the signing key.
  # peek_payload raises on a non-JWT input; a well-formed JWT missing account_id
  # collapses to :malformed via the failed match.
  defp peek_account_id(token) do
    %JOSE.JWT{fields: %{"account_id" => account_id}} = JOSE.JWT.peek_payload(token)
    {:ok, account_id}
  rescue
    _ -> {:error, :malformed}
  end

  defp fetch_account(account_id) do
    with {:ok, account_id} <- Ecto.UUID.cast(account_id) do
      Database.fetch_account(account_id)
    end
  end

  defp verify_exp(%{"exp" => exp} = claims) when is_integer(exp) do
    if DateTime.utc_now() |> DateTime.to_unix() <= exp do
      {:ok, claims}
    else
      {:error, :expired}
    end
  end

  defp verify_exp(_claims), do: {:error, :expired}

  defmodule Database do
    import Ecto.Query
    alias Portal.Account
    alias Portal.Safe

    def fetch_account(account_id) do
      from(a in Account, where: a.id == ^account_id)
      |> Safe.unscoped()
      |> Safe.one()
    end
  end
end
