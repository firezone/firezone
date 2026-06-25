defmodule Portal.FlowLogToken do
  @moduledoc """
  Mints and verifies per-flow ingest tokens.

  A token is a base64url-encoded JSON attribution payload joined to an
  HMAC-SHA256 tag over that encoded payload, keyed by the reporting account's
  symmetric `ingest_signing_key`: `<payload>.<mac>`. It carries an attribution
  snapshot (account, policy, resource, actor and the reporting device + role)
  captured when a flow is authorized. The token is the sole authenticator for
  records posted to `POST /ingestion/flow_logs`: there is no request-level
  credential, so each record proves its own provenance and supplies the
  authoritative attribution fields for the resulting `Portal.FlowLog` row.

  The MAC algorithm is fixed, so there is no algorithm field to negotiate and no
  algorithm-confusion surface. The token signs attribution, not stats: trust in
  the reported byte/packet counts comes from the two-sided cross-check
  (initiator and responder each report independently), not from the MAC.

  `exp` is `authorization_expires_at + 30d`: an absolute grace window so flows
  that finalize and upload long after their authorization is gone (sleep/wake,
  batched late uploads) are still ingestable.
  """
  alias Portal.Account
  alias __MODULE__.Database

  # Grace added to the authorization's expiry to allow late/sleep uploads (30d).
  @reporting_grace_seconds 2_592_000

  # Attribution claims copied verbatim into the flow_logs row on ingest.
  @attribution_claims ~w[role device_id policy_id resource_id resource_name resource_address
                         actor_id actor_email actor_name auth_provider_id authorized_at
                         authorization_expires_at
                         client_version device_os_name device_os_version device_serial device_uuid
                         device_identifier_for_vendor device_firebase_installation_id]

  @type claims :: %{optional(String.t()) => term()}
  @type key_cache :: %{optional(String.t()) => binary() | :not_found}

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

    payload =
      attribution
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.take(@attribution_claims)
      |> Map.put("account_id", account_id)
      |> Map.put("iat", DateTime.to_unix(DateTime.utc_now()))
      |> Map.put("exp", exp)
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    payload <> "." <> sign(payload, key)
  end

  @doc """
  Verify a token and return its claims.

  The endpoint is not pre-authenticated, so verification first decodes the
  (unverified) payload to read the `account_id` claim, loads the signing key,
  then verifies the MAC with that key and finally checks `exp`.
  """
  @spec verify(term()) :: {:ok, claims()} | {:error, :malformed | :invalid | :expired}
  def verify(token), do: token |> verify(%{}) |> elem(0)

  @doc """
  Like `verify/1`, but reuses `cache` (a map of `account_id => signing key`) so a
  batch of records sharing an account performs a single key lookup for the whole
  request. Returns the verify result paired with the updated cache.

  A batch may mix accounts; each entry is keyed independently. An unknown account
  and a bad MAC both collapse to `:invalid` so the endpoint is not an oracle for
  which account ids exist.
  """
  @spec verify(term(), key_cache()) ::
          {{:ok, claims()} | {:error, :malformed | :invalid | :expired}, key_cache()}
  def verify(token, cache) when is_binary(token) do
    case decode(token) do
      {:ok, payload, mac, claims} ->
        {key, cache} = resolve_key(claims, cache)
        {verify_claims(payload, mac, claims, key), cache}

      {:error, reason} ->
        {{:error, reason}, cache}
    end
  end

  def verify(_token, cache), do: {{:error, :malformed}, cache}

  defp decode(token) do
    with {:ok, payload, mac} <- split(token),
         {:ok, claims} <- decode_payload(payload) do
      {:ok, payload, mac, claims}
    end
  end

  defp verify_claims(payload, mac, claims, key) do
    with :ok <- verify_mac(payload, mac, key) do
      verify_exp(claims)
    end
  end

  defp sign(payload, key) do
    :hmac
    |> :crypto.mac(:sha256, key, payload)
    |> Base.url_encode64(padding: false)
  end

  defp split(token) do
    case String.split(token, ".") do
      [payload, mac] when payload != "" and mac != "" -> {:ok, payload, mac}
      _ -> {:error, :malformed}
    end
  end

  defp decode_payload(payload) do
    with {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json) do
      {:ok, claims}
    else
      _ -> {:error, :malformed}
    end
  end

  defp resolve_key(%{"account_id" => account_id}, cache) when is_binary(account_id) do
    case cache do
      %{^account_id => key} ->
        {key, cache}

      _ ->
        key = fetch_key(account_id)
        {key, Map.put(cache, account_id, key)}
    end
  end

  defp resolve_key(_claims, cache), do: {:not_found, cache}

  defp fetch_key(account_id) do
    with {:ok, account_id} <- Ecto.UUID.cast(account_id),
         %Account{ingest_signing_key: key} <- Database.fetch_account(account_id) do
      key
    else
      _ -> :not_found
    end
  end

  # Unknown account and bad MAC collapse to the same error. Constant-time compare
  # among equal-length candidates; the expected MAC length is fixed and public,
  # so short-circuiting a wrong length leaks nothing.
  defp verify_mac(_payload, _mac, :not_found), do: {:error, :invalid}

  defp verify_mac(payload, mac, key) do
    expected = sign(payload, key)

    if byte_size(mac) == byte_size(expected) and :crypto.hash_equals(mac, expected) do
      :ok
    else
      {:error, :invalid}
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
