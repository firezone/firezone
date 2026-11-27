defmodule Portal.DeviceCA.KeyVault do
  @moduledoc """
  Keeps each account's device CA key in Azure Key Vault.
  """
  @behaviour Portal.DeviceCA

  require Logger

  @api_version "7.4"
  @scope "https://vault.azure.net"
  @p256 {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}

  @impl true
  def create_key(account_id) do
    body = %{
      kty: "EC",
      crv: "P-256",
      key_ops: ["sign", "verify"],
      attributes: %{exportable: false},
      tags: %{account_id: account_id}
    }

    case request(:post, vault_url() <> "/keys/device-ca-#{account_id}/create", body) do
      {:ok, %{status: 200, body: %{"key" => %{"kid" => key_id, "crv" => "P-256", "x" => x, "y" => y}}}} ->
        point = <<4>> <> decode!(x) <> decode!(y)
        {:ok, %{key_id: key_id, private_key: nil, public_key: {{:ECPoint, point}, @p256}}}

      other ->
        failed(:create_key, account_id, other)
    end
  end

  @impl true
  def delete_key(account_id) do
    case request(:delete, vault_url() <> "/keys/device-ca-#{account_id}", nil) do
      {:ok, %{status: status}} when status in [200, 404] -> :ok
      other -> failed(:delete_key, account_id, other)
    end
  end

  @impl true
  def sign(%{key_id: key_id}, digest) when is_binary(key_id) do
    with :ok <- in_vault(key_id) do
      body = %{alg: "ES256", value: Base.url_encode64(digest, padding: false)}

      # The device waits and tries again itself, so only a closed pooled connection is retried.
      case request(:post, key_id <> "/sign", body, retry: &retry_closed_connection/2, max_retries: 1) do
        {:ok, %{status: 200, body: %{"value" => value}}} -> der_signature(decode!(value))
        other -> failed(:sign, key_id, other)
      end
    end
  end

  def sign(_key, _digest), do: {:error, :unknown_key}

  # Signing changes nothing in the vault, so a second try is always safe.
  defp retry_closed_connection(_request, %Req.TransportError{reason: :closed}), do: {:delay, 0}
  defp retry_closed_connection(_request, _response_or_exception), do: false

  defp in_vault(key_id) do
    if String.starts_with?(key_id, vault_url() <> "/keys/"),
      do: :ok,
      else: {:error, :key_outside_vault}
  end

  defp request(method, url, body, opts \\ []) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    with {:ok, token} <- token() do
      [
        method: method,
        url: url,
        params: ["api-version": @api_version],
        headers: [{"authorization", "Bearer " <> token}],
        # Only our own vault URL gets here, and it resolves to a private address.
        allow_private_ips: true
      ]
      |> put_body(body)
      |> Keyword.merge(config[:req_opts] || [])
      |> Keyword.merge(opts)
      |> Req.new()
      |> Req.request()
    end
  end

  defp put_body(opts, nil), do: opts
  defp put_body(opts, body), do: Keyword.put(opts, :json, body)

  defp token do
    {:ok, Portal.Azure.ManagedIdentity.access_token!(@scope)}
  rescue
    exception -> {:error, exception}
  end

  defp vault_url do
    Portal.Config.fetch_env!(:portal, :device_ca_key_vault_url) |> String.trim_trailing("/")
  end

  defp decode!(value), do: Base.url_decode64!(value, padding: false)

  # The vault returns r and s side by side. X.509 wants them DER encoded.
  defp der_signature(<<r::unsigned-size(256), s::unsigned-size(256)>>),
    do: {:ok, :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})}

  defp der_signature(_value), do: {:error, :bad_signature}

  defp failed(_operation, _key, {:ok, %Req.Response{status: 429}}), do: {:error, :throttled}

  defp failed(operation, key, result) do
    Logger.error("Device CA Key Vault request failed",
      operation: operation,
      key: key,
      status: status(result),
      reason: reason(result)
    )

    {:error, :unavailable}
  end

  defp status({:ok, %Req.Response{status: status}}), do: status
  defp status(_result), do: nil

  defp reason({:ok, %Req.Response{body: %{"error" => %{"code" => code}}}}), do: code
  defp reason({:error, exception}) when is_exception(exception), do: Exception.message(exception)
  defp reason(_result), do: nil
end
