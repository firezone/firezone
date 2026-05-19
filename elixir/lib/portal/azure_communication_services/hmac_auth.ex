defmodule Portal.AzureCommunicationServices.HMACAuth do
  @moduledoc false

  @spec attach(Req.Request.t(), String.t()) :: Req.Request.t()
  def attach(%Req.Request{} = req, access_key) when is_binary(access_key) do
    Req.Request.append_request_steps(req,
      refresh_acs_hmac_auth: &wrap_adapter(&1, access_key)
    )
  end

  defp wrap_adapter(%Req.Request{adapter: original_adapter} = req, access_key) do
    req
    |> Req.Request.put_private(:acs_hmac_original_adapter, original_adapter)
    |> Map.put(:adapter, &sign_and_run(&1, access_key))
  end

  defp sign_and_run(%Req.Request{} = req, access_key) do
    timestamp = timestamp()
    content_hash = content_hash(req.body)
    host = host(req.url)

    req =
      req
      |> Req.Request.put_header("x-ms-date", timestamp)
      |> Req.Request.put_header("x-ms-content-sha256", content_hash)
      |> Req.Request.put_header("host", host)
      |> Req.Request.put_header(
        "authorization",
        authorization(req, access_key, timestamp, content_hash, host)
      )

    original_adapter =
      Req.Request.get_private(req, :acs_hmac_original_adapter, &Req.Steps.run_finch/1)

    original_adapter.(req)
  end

  defp authorization(req, access_key, timestamp, content_hash, host) do
    signature =
      req
      |> string_to_sign(timestamp, content_hash, host)
      |> sign(access_key)

    "HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature=#{signature}"
  end

  defp string_to_sign(req, timestamp, content_hash, host),
    do: "POST\n#{path_and_query(req.url)}\n#{timestamp};#{host};#{content_hash}"

  defp sign(string_to_sign, access_key) do
    key = Base.decode64!(access_key)
    :crypto.mac(:hmac, :sha256, key, string_to_sign) |> Base.encode64()
  end

  defp timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp content_hash(body) do
    :crypto.hash(:sha256, body) |> Base.encode64()
  end

  defp host(%URI{} = uri) do
    if uri.port in [80, 443, nil] do
      uri.host
    else
      "#{uri.host}:#{uri.port}"
    end
  end

  defp path_and_query(%URI{path: path, query: nil}), do: path
  defp path_and_query(%URI{path: path, query: query}), do: "#{path}?#{query}"
end
