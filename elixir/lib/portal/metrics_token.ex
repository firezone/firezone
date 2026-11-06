defmodule Portal.MetricsToken do
  @moduledoc """
  Mints the tokens Clients and Gateways present to the OTLP ingest proxy.

  A token is an EdDSA JWT signed with `otel_ingest_jwt_private_key`. It names
  the account (id and slug) the metrics are attributed to, the device (id, type
  and version) it was minted for, and the metric name patterns it may export.
  """
  alias Portal.{Account, Device}

  @ttl_seconds 3600

  def ttl_seconds, do: @ttl_seconds

  @doc """
  Whether a signing key is configured.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(Portal.Config.get_env(:portal, :otel_ingest_jwt_private_key))

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
        "device_id" => device.id,
        "device_type" => Atom.to_string(device.type),
        "device_version" => device.last_seen_version,
        "metrics" => patterns,
        "iat" => now,
        "exp" => now + @ttl_seconds
      }
      |> Map.reject(fn {_claim, value} -> is_nil(value) end)

    jwk()
    |> JOSE.JWT.sign(%{"alg" => "EdDSA"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp jwk do
    Portal.Config.fetch_env!(:portal, :otel_ingest_jwt_private_key)
    |> Base.decode64!()
    |> JOSE.JWK.from_pem()
  end
end
