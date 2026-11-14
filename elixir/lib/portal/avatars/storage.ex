defmodule Portal.Avatars.Storage do
  @moduledoc """
  Reads and writes profile photos in the blob container at
  `avatars_container_url`. Requests carry the portal's managed identity token.
  """

  @api_version "2020-12-06"
  @scope "https://storage.azure.com/"
  @months ~w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]

  def put!(name, body, content_type) do
    %Req.Response{status: 201} =
      request!(:put, blob_url(name),
        body: body,
        headers: [
          {"x-ms-blob-type", "BlockBlob"},
          {"x-ms-blob-content-type", content_type},
          {"content-type", content_type}
        ]
      )

    :ok
  end

  def get(name) do
    case request(:get, blob_url(name), decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, _reason} = error -> error
    end
  end

  def delete!(name) do
    %Req.Response{status: status} = request!(:delete, blob_url(name), [])
    true = status in [202, 404]
    :ok
  end

  @doc """
  Lists the blobs that start with `prefix` as `{name, last_modified}`.
  """
  def list!(prefix), do: list!(prefix, nil, [])

  defp list!(prefix, marker, acc) do
    params =
      [restype: "container", comp: "list", prefix: prefix]
      |> then(&if(marker, do: &1 ++ [marker: marker], else: &1))

    %Req.Response{status: 200, body: body} =
      request!(:get, container_url(), params: params, decode_body: false)

    names =
      for [blob] <- Regex.scan(~r{<Blob>.*?</Blob>}s, body),
          [_match, name] <- [Regex.run(~r{<Name>([^<]+)</Name>}, blob)],
          [_match, modified] <- [Regex.run(~r{<Last-Modified>([^<]+)</Last-Modified>}, blob)],
          do: {name, parse_http_date!(modified)}

    case Regex.run(~r{<NextMarker>([^<]+)</NextMarker>}, body) do
      [_match, next] -> list!(prefix, next, acc ++ names)
      nil -> acc ++ names
    end
  end

  # RFC 1123, as in "Sat, 14 Nov 2026 13:59:43 GMT".
  defp parse_http_date!(value) do
    [_match, day, month, year, time] =
      Regex.run(~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) GMT$/, value)

    month = Enum.find_index(@months, &(&1 == month)) + 1
    date = Date.new!(String.to_integer(year), month, String.to_integer(day))
    DateTime.new!(date, Time.from_iso8601!(time), "Etc/UTC")
  end

  defp request!(method, url, opts) do
    method |> request_opts(url, opts) |> Req.request!()
  end

  defp request(method, url, opts) do
    method |> request_opts(url, opts) |> Req.request()
  end

  defp request_opts(method, url, opts) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    token = Portal.Azure.ManagedIdentity.access_token!(@scope)

    [
      method: method,
      url: url,
      headers: [
        {"authorization", "Bearer " <> token},
        {"x-ms-version", @api_version},
        {"x-ms-date", Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")}
      ]
    ]
    |> Keyword.merge(config[:req_opts] || [])
    |> Keyword.merge(opts, fn
      :headers, base, extra -> base ++ extra
      _key, _base, extra -> extra
    end)
  end

  defp blob_url(name), do: "#{container_url()}/#{name}"

  defp container_url do
    case Portal.Config.fetch_env!(:portal, :avatars_container_url) do
      nil -> raise "avatars_container_url is not configured"
      url -> String.trim_trailing(url, "/")
    end
  end
end
