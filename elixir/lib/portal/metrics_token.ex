defmodule Portal.MetricsToken do
  @moduledoc """
  Mints and verifies the tokens Clients and Gateways present to `POST /v1/metrics`.

  A token is an HS256 JWT signed with the account's `ingest_signing_key`. It
  names the account (id and slug) the metrics are attributed to and which
  metrics may be forwarded. The `metrics` claim is either `%{"all" => true}` or
  `%{"names" => [...]}`; any other shape is rejected, so an empty or missing
  list never widens to "all".

  The accepted algorithm is pinned to HS256 on verify (`verify_strict`), so a
  token presenting another `alg` (including `none`) is rejected.
  """
  alias Portal.Account
  alias __MODULE__.Database

  @ttl_seconds 6 * 3600

  @type claims :: %{optional(String.t()) => term()}

  def ttl_seconds, do: @ttl_seconds

  @doc """
  Mints a token for `account` allowing `metrics`: `:all` or a list of metric names.
  """
  @spec mint(Account.t(), :all | [String.t()]) :: String.t()
  def mint(%Account{} = account, metrics \\ :all) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    claims = %{
      "account_id" => account.id,
      "account_slug" => account.slug,
      "metrics" => metrics_claim(metrics),
      "iat" => now,
      "exp" => now + @ttl_seconds
    }

    account.ingest_signing_key
    |> jwk()
    |> JOSE.JWT.sign(%{"alg" => "HS256"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  @doc """
  Verifies a token and returns its claims.

  An unknown or disabled account and a bad signature all collapse to `:invalid`
  so the endpoint is not an oracle for which account ids exist.
  """
  @spec verify(term()) :: {:ok, claims()} | {:error, :malformed | :invalid | :expired}
  def verify(token) when is_binary(token) do
    with {:ok, account_id} <- peek_account_id(token),
         %Account{ingest_signing_key: key} = account <- fetch_account(account_id),
         true <- Account.active?(account),
         {true, %JOSE.JWT{fields: claims}, _jws} <-
           JOSE.JWT.verify_strict(jwk(key), ["HS256"], token),
         :ok <- verify_exp(claims),
         :ok <- verify_metrics_claim(claims) do
      {:ok, claims}
    else
      {:error, reason} when reason in [:malformed, :expired] -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :malformed}

  @doc """
  Returns whether verified `claims` allow forwarding the metric `name`.
  """
  @spec allows?(claims(), String.t()) :: boolean()
  def allows?(%{"metrics" => %{"all" => true}}, _name), do: true
  def allows?(%{"metrics" => %{"names" => names}}, name), do: name in names

  defp metrics_claim(:all), do: %{"all" => true}
  defp metrics_claim(names) when is_list(names), do: %{"names" => names}

  defp jwk(key), do: JOSE.JWK.from_oct(key)

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

  defp verify_exp(%{"exp" => exp}) when is_integer(exp) do
    if DateTime.utc_now() |> DateTime.to_unix() <= exp do
      :ok
    else
      {:error, :expired}
    end
  end

  defp verify_exp(_claims), do: {:error, :expired}

  defp verify_metrics_claim(%{"metrics" => %{"all" => true} = metrics})
       when map_size(metrics) == 1,
       do: :ok

  defp verify_metrics_claim(%{"metrics" => %{"names" => names} = metrics})
       when map_size(metrics) == 1 and is_list(names) do
    if Enum.all?(names, &is_binary/1), do: :ok, else: {:error, :malformed}
  end

  defp verify_metrics_claim(_claims), do: {:error, :malformed}

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
