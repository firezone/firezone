defmodule Portal.MetricsToken do
  @moduledoc """
  Mints and verifies the tokens Clients and Gateways present to `POST /v1/metrics`.

  A token is an HS256 JWT. It names the account (id and slug) the metrics are
  attributed to, the type (`"client"` or `"gateway"`) and version of the device
  it was minted for, and which metrics may be forwarded. The `metrics` claim is a
  list of metric name patterns in which `*` matches any run of characters, so
  `["*"]` allows every metric. A claim of any other shape is rejected, and an
  empty list allows nothing.

  The accepted algorithm is pinned to HS256 on verify (`verify_strict`), so a
  token presenting another `alg` (including `none`) is rejected.

  Tokens are signed with a key derived from the portal's `secret_key_base` and
  the newest salt in `metrics_token_signing_salts`, so the database alone is not
  enough to mint tokens. Each node caches the key in `:persistent_term` and reads
  the database only when that cache is empty, so verifying a token needs no
  database lookup. `Portal.Ops.rotate_metrics_token_key/0` replaces the key on
  every node.
  """
  alias Portal.{Account, Device}
  alias __MODULE__.Database

  @ttl_seconds 3600
  @signing_key_slot {__MODULE__, :signing_key}
  @key_rotations_topic "metrics_token_key_rotations"

  @type claims :: %{optional(String.t()) => term()}

  def ttl_seconds, do: @ttl_seconds

  @doc """
  Subscribes to `:metrics_token_key_rotated`, sent once this node signs with a new key.
  """
  def subscribe_to_key_rotations, do: Portal.PubSub.subscribe(@key_rotations_topic)

  @doc false
  def activate_signing_salt(salt) when is_binary(salt) do
    :persistent_term.put(@signing_key_slot, derive_jwk(salt))
    Phoenix.PubSub.local_broadcast(Portal.PubSub, @key_rotations_topic, :metrics_token_key_rotated)
  end

  @doc """
  Mints a token for `device` of `account` allowing the metrics matching `patterns`.
  """
  @spec mint(Account.t(), Device.t(), [String.t()]) :: String.t()
  def mint(%Account{} = account, %Device{} = device, patterns) when is_list(patterns) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    claims =
      %{
        "account_id" => account.id,
        "account_slug" => account.slug,
        "device_type" => Atom.to_string(device.type),
        "device_version" => device.last_seen_version,
        "metrics" => patterns,
        "iat" => now,
        "exp" => now + @ttl_seconds
      }
      |> Map.reject(fn {_claim, value} -> is_nil(value) end)

    jwk()
    |> JOSE.JWT.sign(%{"alg" => "HS256"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  @doc """
  Verifies a token and returns its claims.
  """
  @spec verify(term()) :: {:ok, claims()} | {:error, :malformed | :invalid | :expired}
  def verify(token) when is_binary(token) do
    with {:ok, claims} <- verify_signature(jwk(), token),
         :ok <- verify_exp(claims),
         :ok <- verify_device(claims),
         :ok <- verify_metrics_claim(claims) do
      {:ok, claims}
    end
  end

  def verify(_token), do: {:error, :malformed}

  @doc """
  Returns whether verified `claims` allow forwarding the metric `name`.
  """
  @spec allows?(claims(), String.t()) :: boolean()
  def allows?(%{"metrics" => patterns}, name), do: Enum.any?(patterns, &matches?(&1, name))

  defp matches?(pattern, name) do
    case String.split(pattern, "*") do
      [exact] -> exact == name
      [prefix | parts] -> String.starts_with?(name, prefix) and matches_parts?(skip(name, prefix), parts)
    end
  end

  defp matches_parts?(rest, [suffix]), do: String.ends_with?(rest, suffix)
  defp matches_parts?(rest, ["" | parts]), do: matches_parts?(rest, parts)

  defp matches_parts?(rest, [part | parts]) do
    case :binary.match(rest, part) do
      {start, length} -> matches_parts?(skip(rest, start + length), parts)
      :nomatch -> false
    end
  end

  defp skip(binary, bytes) when is_integer(bytes), do: binary_part(binary, bytes, byte_size(binary) - bytes)
  defp skip(binary, prefix), do: skip(binary, byte_size(prefix))

  defp verify_signature(jwk, token) do
    case JOSE.JWT.verify_strict(jwk, ["HS256"], token) do
      {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :malformed}
  end

  defp jwk do
    case :persistent_term.get(@signing_key_slot, nil) do
      nil ->
        jwk = derive_jwk(Database.fetch_active_salt!())
        :persistent_term.put(@signing_key_slot, jwk)
        jwk

      jwk ->
        jwk
    end
  end

  defp derive_jwk(salt) do
    secret_key_base =
      Application.fetch_env!(:portal, PortalWeb.Endpoint)
      |> Keyword.fetch!(:secret_key_base)

    :hmac
    |> :crypto.mac(:sha256, secret_key_base, salt)
    |> JOSE.JWK.from_oct()
  end

  defp verify_exp(%{"exp" => exp}) when is_integer(exp) do
    if DateTime.utc_now() |> DateTime.to_unix() <= exp do
      :ok
    else
      {:error, :expired}
    end
  end

  defp verify_exp(_claims), do: {:error, :expired}

  defp verify_device(%{"device_type" => type} = claims) when type in ["client", "gateway"] do
    if is_binary(Map.get(claims, "device_version", "")), do: :ok, else: {:error, :malformed}
  end

  defp verify_device(_claims), do: {:error, :malformed}

  defp verify_metrics_claim(%{"metrics" => patterns}) when is_list(patterns) do
    if Enum.all?(patterns, &is_binary/1), do: :ok, else: {:error, :malformed}
  end

  defp verify_metrics_claim(_claims), do: {:error, :malformed}

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def fetch_active_salt! do
      from(s in "metrics_token_signing_salts", order_by: [desc: s.id], limit: 1, select: s.salt)
      |> Safe.unscoped()
      |> Safe.one!()
    end
  end
end
