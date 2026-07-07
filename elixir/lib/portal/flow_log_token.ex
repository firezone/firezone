defmodule Portal.FlowLogToken do
  @moduledoc """
  Mints and verifies per-authorization flow-log ingest tokens.

  A token is a standard HS256 JWT signed with the reporting account's symmetric
  `ingest_signing_key`. It carries an attribution snapshot (account, policy
  authorization, policy, resource, actor and the reporting device + role)
  captured when a flow is authorized. The token is the sole authenticator for
  `POST /ingestion/flow_logs`: it is sent once per request in the
  `Authorization: Bearer` header (not per record), so every record in a request
  is attributed to the single policy authorization the token names and there is
  no other request-level credential.

  The accepted algorithm is pinned to HS256 on verify (`verify_strict`), so a
  token presenting another `alg` (including `none`) is rejected and there is no
  algorithm-confusion surface. The token signs attribution, not stats: trust in
  the reported byte/packet counts comes from the two-sided cross-check
  (initiator and responder each report independently), not from the signature.

  `exp` is `authorization_expires_at + 30d`: an absolute grace window so flows
  that finalize and upload long after their authorization is gone (sleep/wake,
  batched late uploads) are still ingestable.
  """
  alias Portal.Account
  alias __MODULE__.Database

  # Grace added to the authorization's expiry to allow late/sleep uploads (30d).
  @reporting_grace_seconds 2_592_000

  # Attribution claims copied verbatim into the flow_logs row on ingest, plus
  # `flow_log_uploads_enabled`, which gates ingestion instead of being stored.
  @attribution_claims ~w[role device_id policy_authorization_id policy_id flow_log_uploads_enabled
                         resource_id resource_name
                         resource_address actor_id actor_email actor_name auth_provider_id
                         authorized_at authorization_expires_at
                         client_version device_os_name device_os_version device_serial device_uuid
                         device_identifier_for_vendor device_firebase_installation_id]

  @type claims :: %{optional(String.t()) => term()}

  @doc """
  Mint a token for `account` carrying `attribution`, expiring at
  `authorization_expires_at` plus the reporting grace window.

  `attribution` keys may be atoms or strings and are restricted to the known
  attribution claims; `account_id`, `iat` and `exp` are stamped by this function.
  """
  @spec mint(Account.t(), map(), DateTime.t()) :: String.t()
  def mint(%Account{ingest_signing_key: key, id: account_id}, attribution, authorization_expires_at) do
    exp =
      authorization_expires_at
      |> DateTime.add(@reporting_grace_seconds, :second)
      |> DateTime.to_unix()

    claims =
      attribution
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.take(@attribution_claims)
      # Drop absent attribution: JOSE's JSON codec round-trips `null` as the atom
      # `:null` (not `nil`), which would fail to cast into a flow_logs column. An
      # omitted claim reads back as `nil` on verify, which is what we want for the
      # nullable attribution fields (resource_address, actor_email, etc.).
      |> Map.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.put("account_id", account_id)
      |> Map.put("iat", DateTime.to_unix(DateTime.utc_now()))
      |> Map.put("exp", exp)

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
         {true, %JOSE.JWT{fields: claims}, _jws} <- JOSE.JWT.verify_strict(jwk(key), ["HS256"], token) do
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
      |> Safe.unscoped(:replica)
      |> Safe.one(fallback_to_primary: true)
    end
  end
end
