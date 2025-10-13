defmodule Domain.GoogleCloudPlatform.URLSigner do
  def sign_url(oauth_identity, oauth_access_token, bucket, filename, opts \\ []) do
    sign_endpoint_url = Keyword.fetch!(opts, :sign_endpoint_url)
    sign_endpoint_url = sign_endpoint_url <> oauth_identity <> ":signBlob"

    cloud_storage_url = Keyword.fetch!(opts, :cloud_storage_url)
    cloud_storage_host = URI.parse(cloud_storage_url).host

    valid_from = Keyword.get(opts, :valid_from, DateTime.utc_now())
    valid_from = DateTime.truncate(valid_from, :second)
    valid_from_date = DateTime.to_date(valid_from)

    verb = Keyword.get(opts, :verb, "GET")
    expires_in = Keyword.get(opts, :expires_in, 60 * 60 * 24 * 7)

    headers = Keyword.get(opts, :headers, [])
    headers = prepare_headers(headers, cloud_storage_host)
    canonical_headers = canonical_headers(headers)
    signed_headers = signed_headers(headers)

    path = Path.join("/", Path.join(bucket, filename))

    credential_scope = "#{Date.to_iso8601(valid_from_date, :basic)}/auto/storage/goog4_request"

    canonical_query_string =
      [
        {"X-Goog-Algorithm", "GOOG4-RSA-SHA256"},
        {"X-Goog-Credential", "#{oauth_identity}/#{credential_scope}"},
        {"X-Goog-Date", DateTime.to_iso8601(valid_from, :basic)},
        {"X-Goog-SignedHeaders", signed_headers},
        {"X-Goog-Expires", expires_in}
      ]
      |> Enum.sort()
      |> URI.encode_query(:rfc3986)

    canonical_request =
      [
        verb,
        path,
        canonical_query_string,
        canonical_headers,
        "",
        signed_headers,
        "UNSIGNED-PAYLOAD"
      ]
      |> Enum.join("\n")

    string_to_sign =
      [
        "GOOG4-RSA-SHA256",
        DateTime.to_iso8601(valid_from, :basic),
        "#{Date.to_iso8601(valid_from_date, :basic)}/auto/storage/goog4_request",
        Domain.Crypto.hash(:sha256, canonical_request)
      ]
      |> Enum.join("\n")
      |> Base.encode64()

    request =
      Finch.build(
        :post,
        sign_endpoint_url,
        [{"Authorization", "Bearer #{oauth_access_token}"}],
        JSON.encode!(%{"payload" => string_to_sign})
      )

    with {:ok, %Finch.Response{status: 200, body: response}} <-
           Finch.request(request, Domain.GoogleCloudPlatform.Finch),
         {:ok, %{"signedBlob" => signature}} <- JSON.decode(response) do
      signature =
        signature
        |> Base.decode64!()
        |> Base.encode16()
        |> String.downcase()

      {:ok,
       "https://#{cloud_storage_host}#{path}?#{canonical_query_string}&X-Goog-Signature=#{signature}"}
    else
      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, {status, body}}

      {:ok, map} ->
        {:error, map}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_headers(headers, host) do
    headers = [host: host] ++ headers

    headers
    |> Enum.map(fn {k, v} -> {k |> to_string() |> String.downcase(), v} end)
    |> Enum.sort(fn {k1, _}, {k2, _} -> k1 <= k2 end)
  end

  @doc false
  def canonical_headers(headers) do
    headers
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map_join("\n", fn {k, v} -> "#{k}:#{Enum.join(v, ",")}" end)
  end

  def signed_headers(headers) do
    headers
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.join(";")
  end
end
