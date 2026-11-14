defmodule Portal.Config.AzureTest do
  use ExUnit.Case, async: true
  alias Portal.Config.Azure

  @endpoint "https://fzconfigtest.azconfig.io"
  @key_vault_reference "application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8"

  defp http_get(routes) do
    test_pid = self()

    fn url, headers ->
      send(test_pid, {:get, url, headers})

      Enum.find_value(routes, {:error, :unexpected_request}, fn {prefix, response} ->
        if String.starts_with?(url, prefix), do: response
      end)
    end
  end

  defp token(token), do: {:ok, 200, JSON.encode!(%{"access_token" => token})}

  defp page(items, next_link \\ nil) do
    body = %{"items" => items}
    body = if next_link, do: Map.put(body, "@nextLink", next_link), else: body
    {:ok, 200, JSON.encode!(body)}
  end

  defp imds(resource),
    do: "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=#{URI.encode_www_form(resource)}"

  test "returns unlabeled settings across pages" do
    http_get =
      http_get([
        {imds("https://azconfig.io"), token("store-token")},
        {"#{@endpoint}/kv?label=%00", page([%{"key" => "LOG_LEVEL", "value" => "info"}], "/kv?after=1")},
        {"#{@endpoint}/kv?after=1", page([%{"key" => "WEB_EXTERNAL_URL", "value" => "https://app.example.com"}])}
      ])

    assert Azure.fetch_settings!(@endpoint <> "/", "client-id", http_get) == %{
             "LOG_LEVEL" => "info",
             "WEB_EXTERNAL_URL" => "https://app.example.com"
           }

    assert_received {:get, token_url, [{"Metadata", "true"}]}
    assert token_url =~ "client_id=client-id"
    assert_received {:get, "#{@endpoint}/kv?label=%00&api-version=2023-11-01", [{"Authorization", "Bearer store-token"}]}
    refute_received {:get, "http://169.254.169.254" <> _, _headers}
  end

  test "resolves Key Vault references with a Key Vault token" do
    http_get =
      http_get([
        {imds("https://azconfig.io"), token("store-token")},
        {imds("https://vault.azure.net"), token("vault-token")},
        {"#{@endpoint}/kv",
         page([
           %{
             "key" => "SECRET_KEY_BASE",
             "content_type" => @key_vault_reference,
             "value" => JSON.encode!(%{"uri" => "https://fzconfigtest.vault.azure.net/secrets/secret-key-base/v1"})
           }
         ])},
        {"https://fzconfigtest.vault.azure.net/secrets/secret-key-base/v1", {:ok, 200, JSON.encode!(%{"value" => "s3cret"})}}
      ])

    assert Azure.fetch_settings!(@endpoint, "client-id", http_get) == %{"SECRET_KEY_BASE" => "s3cret"}

    assert_received {:get, "https://fzconfigtest.vault.azure.net/secrets/secret-key-base/v1?api-version=7.4",
                     [{"Authorization", "Bearer vault-token"}]}
  end

  test "never sends a Key Vault token outside Key Vault" do
    http_get =
      http_get([
        {imds("https://azconfig.io"), token("store-token")},
        {imds("https://vault.azure.net"), token("vault-token")},
        {"#{@endpoint}/kv",
         page([
           %{
             "key" => "SECRET_KEY_BASE",
             "content_type" => @key_vault_reference,
             "value" => JSON.encode!(%{"uri" => "https://attacker.example.com/secrets/secret-key-base"})
           }
         ])}
      ])

    assert_raise RuntimeError, "SECRET_KEY_BASE references a secret outside Azure Key Vault", fn ->
      Azure.fetch_settings!(@endpoint, "client-id", http_get)
    end

    refute_received {:get, "https://attacker.example.com" <> _, _headers}
  end

  test "raises without the response body when the store rejects the request" do
    http_get =
      http_get([
        {imds("https://azconfig.io"), token("store-token")},
        {"#{@endpoint}/kv", {:ok, 403, "do not leak this body"}}
      ])

    assert_raise RuntimeError, "request to fzconfigtest.azconfig.io failed with HTTP 403", fn ->
      Azure.fetch_settings!(@endpoint, "client-id", http_get)
    end
  end
end
