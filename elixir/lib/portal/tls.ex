defmodule Portal.TLS do
  @moduledoc false

  def sni_fun(hosts, mtls_external_url) when is_map(hosts) do
    mtls_host = external_host(mtls_external_url)

    hosts =
      Map.new(hosts, fn
        {host, %{"certfile" => certfile, "keyfile" => keyfile}}
        when is_binary(host) and is_binary(certfile) and is_binary(keyfile) ->
          options = [certfile: String.to_charlist(certfile), keyfile: String.to_charlist(keyfile)]
          host = String.downcase(host)
          {host, maybe_require_client_certificate(options, host, mtls_host)}

        {host, options} ->
          raise ArgumentError,
                "invalid TLS configuration for #{inspect(host)}: #{inspect(options)}"
      end)

    fn hostname -> Map.get(hosts, hostname |> to_string() |> String.downcase(), :unrecognized) end
  end

  def verify_client_certificate(_certificate, _event, state), do: {:valid, state}

  defp maybe_require_client_certificate(options, host, host) do
    # TLS proves possession of the private key here. The socket authenticates
    # the leaf against the account-specific trust anchors after connecting.
    options ++
      [
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        certificate_authorities: false,
        cacerts: [],
        verify_fun: {&__MODULE__.verify_client_certificate/3, nil}
      ]
  end

  defp maybe_require_client_certificate(options, _host, _mtls_host), do: options

  defp external_host(url) when is_binary(url) do
    case URI.parse(url).host do
      host when is_binary(host) -> String.downcase(host)
      nil -> nil
    end
  end
  defp external_host(_url), do: nil
end
