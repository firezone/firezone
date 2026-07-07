# Vendored from https://github.com/firezone/openid_connect, a fork of
# https://github.com/DockYard/openid_connect by DockYard, Inc.
# MIT licensed; see lib/openid_connect/LICENSE.md.
defmodule OpenIDConnect.Document do
  @moduledoc """
  This module caches OIDC documents and their JWKs for a limited timeframe, which is min(`@refresh_time`, `document.remaining_lifetime`).
  """
  alias OpenIDConnect.Document.Cache

  defstruct raw: nil,
            authorization_endpoint: nil,
            end_session_endpoint: nil,
            token_endpoint: nil,
            userinfo_endpoint: nil,
            claims_supported: nil,
            response_types_supported: nil,
            jwks: nil,
            expires_at: nil

  @refresh_time_seconds Application.compile_env(
                          :portal,
                          [OpenIDConnect, :document_max_expiration_seconds],
                          60 * 60
                        )

  @document_max_byte_size Application.compile_env(
                            :portal,
                            [OpenIDConnect, :document_max_byte_size],
                            1024 * 1024
                          )

  @doc "Returns the cached document for `uri`, fetching and caching it on a cache miss."
  def fetch_document(uri, req_opts \\ []) do
    with :error <- Cache.fetch(uri) do
      refresh_document(uri, req_opts)
    end
  end

  @doc "Fetches a fresh document bypassing the cache. Replaces the cached entry only on success."
  def refresh_document(uri, req_opts \\ []) do
    with {:ok, document_json, document_expires_at} <- fetch_remote_resource(uri, req_opts),
         {:ok, document} <- build_document(document_json),
         {:ok, jwks_json, jwks_expires_at} <-
           fetch_remote_resource(document_json["jwks_uri"], req_opts),
         {:ok, jwks} <- from_certs(jwks_json) do
      now = DateTime.utc_now()

      expires_at =
        [
          DateTime.add(now, @refresh_time_seconds, :second),
          document_expires_at,
          jwks_expires_at
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.min(DateTime)

      document = %{
        document
        | jwks: jwks,
          expires_at: expires_at
      }

      Cache.put(uri, document)

      {:ok, document}
    end
  end

  defp fetch_remote_resource(uri, _req_opts) when is_nil(uri),
    do: {:error, :invalid_discovery_document_uri}

  defp fetch_remote_resource(uri, req_opts) do
    with {:ok, %{headers: headers, body: response, status: status}}
         when status in 200..299 <- read_response(uri, req_opts),
         {:ok, json} <- JSON.decode(response) do
      expires_at =
        if remaining_lifetime = remaining_lifetime(headers) do
          DateTime.add(DateTime.utc_now(), remaining_lifetime, :second)
        end

      {:ok, json, expires_at}
    else
      {:ok, %{body: body, status: status}} ->
        {:error, {status, body}}

      other ->
        other
    end
  end

  defp read_response(uri, req_opts) do
    collector = body_collector(@document_max_byte_size)
    options = Keyword.merge([into: collector, retry: retry_option()], req_opts)

    case Req.get(uri, options) do
      {:ok, %{body: {:error, :body_too_large}}} ->
        {:error, :discovery_document_is_too_large}

      {:ok, %{body: {:ok, body}} = response} ->
        {:ok, %{response | body: IO.iodata_to_binary(body)}}

      # Fallback for empty responses or when body_collector was never invoked
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp body_collector(max_byte_size) do
    fn {:data, data}, {req, resp} ->
      {action, body} = collect_body_chunk(resp.body, data, max_byte_size)
      {action, {req, %{resp | body: body}}}
    end
  end

  defp collect_body_chunk(body, data, max_byte_size) do
    acc = normalize_body_acc(body)

    case acc do
      {:error, _} = error ->
        {:cont, error}

      {:ok, chunks} ->
        new_size = IO.iodata_length(chunks) + byte_size(data)

        if new_size > max_byte_size do
          # Use :cont instead of :halt because Req.Test's Plug adapter doesn't support :halt.
          # Once we exceed the limit, we keep returning the error and ignore further data.
          {:cont, {:error, :body_too_large}}
        else
          {:cont, {:ok, [chunks, data]}}
        end
    end
  end

  defp normalize_body_acc({:ok, _} = ok), do: ok
  defp normalize_body_acc({:error, _} = error), do: error
  defp normalize_body_acc(_), do: {:ok, []}

  defp remaining_lifetime(headers) do
    max_age = get_max_age(headers)
    age = get_age(headers)

    cond do
      not is_nil(max_age) and max_age > 0 and not is_nil(age) -> max_age - age
      not is_nil(max_age) and max_age > 0 -> max_age
      true -> nil
    end
  end

  # Req returns headers as %{"header-name" => ["value1", "value2"]}.
  # The binary fallback handles Plug/Bypass test fixtures which use single string values.
  defp get_header(headers, name) do
    case Map.get(headers, name) do
      nil -> nil
      [value | _] -> value
      value when is_binary(value) -> value
    end
  end

  defp get_max_age(headers) do
    case get_header(headers, "cache-control") do
      nil ->
        nil

      cache_control ->
        case Regex.run(~r"(?<=max-age=)\d+", cache_control) do
          [max_age] -> String.to_integer(max_age)
          _ -> nil
        end
    end
  end

  defp get_age(headers) do
    case get_header(headers, "age") do
      nil -> nil
      age -> String.to_integer(age)
    end
  end

  defp build_document(document_json) do
    required_keys = ["jwks_uri", "authorization_endpoint", "token_endpoint"]

    if Enum.all?(required_keys, &Map.has_key?(document_json, &1)) do
      document = %__MODULE__{
        raw: document_json,
        authorization_endpoint: Map.fetch!(document_json, "authorization_endpoint"),
        end_session_endpoint: Map.get(document_json, "end_session_endpoint"),
        token_endpoint: Map.fetch!(document_json, "token_endpoint"),
        userinfo_endpoint: Map.get(document_json, "userinfo_endpoint"),
        response_types_supported:
          Map.get(document_json, "response_types_supported")
          |> Enum.map(fn response_type ->
            response_type
            |> String.split()
            |> Enum.sort()
            |> Enum.join(" ")
          end),
        claims_supported:
          Map.get(document_json, "claims_supported")
          |> sort_claims()
      }

      {:ok, document}
    else
      {:error, :invalid_document}
    end
  end

  defp sort_claims(nil), do: nil
  defp sort_claims(claims), do: Enum.sort(claims)

  defp from_certs(certs) do
    {:ok, JOSE.JWK.from(certs)}
  rescue
    _ -> {:error, :invalid_jwks_certificates}
  end

  defp retry_option do
    Application.get_env(:portal, OpenIDConnect, [])
    |> Keyword.get(:retry, :safe_transient)
  end
end
