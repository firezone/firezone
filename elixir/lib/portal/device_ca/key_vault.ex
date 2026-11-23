defmodule Portal.DeviceCA.KeyVault do
  @moduledoc """
  Keeps each account's device CA key in Azure Key Vault.
  """
  @behaviour Portal.DeviceCA

  require Logger

  @api_version "7.4"
  @scope "https://vault.azure.net"

  @impl true
  def create_key(account_id) do
    body = %{
      kty: "RSA",
      key_size: 2048,
      key_ops: ["sign", "verify"],
      attributes: %{exportable: false},
      tags: %{account_id: account_id}
    }

    case request(:post, vault_url() <> "/keys/device-ca-#{account_id}/create", body) do
      {:ok, %{status: 200, body: %{"key" => %{"kid" => key_id, "n" => n, "e" => e}}}} ->
        {:ok, %{key_id: key_id, public_key: {:RSAPublicKey, unsigned!(n), unsigned!(e)}}}

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
  def sign(key_id, digest) do
    with :ok <- in_vault(key_id) do
      case request(:post, key_id <> "/sign", %{alg: "RS256", value: Base.url_encode64(digest, padding: false)}) do
        {:ok, %{status: 200, body: %{"value" => value}}} -> {:ok, decode!(value)}
        other -> failed(:sign, key_id, other)
      end
    end
  end

  defp in_vault(key_id) do
    if String.starts_with?(key_id, vault_url() <> "/keys/"),
      do: :ok,
      else: {:error, :key_outside_vault}
  end

  defp request(method, url, body) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    with {:ok, token} <- token() do
      [
        method: method,
        url: url,
        params: ["api-version": @api_version],
        headers: [{"authorization", "Bearer " <> token}]
      ]
      |> put_body(body)
      |> Keyword.merge(config[:req_opts] || [])
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
  defp unsigned!(value), do: value |> decode!() |> :binary.decode_unsigned()

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
