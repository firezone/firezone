defmodule FzHttp.Config.Dumper do
  @doc ~S"""
  Maps JSON-decoded ssl opts to pass to Erlang's ssl module. Most users
  don't need to override many, if any, SSL opts. Most commonly this is
  to use custom cacert files and TLS versions.

  ## Examples:

      iex> FzCommon.dump_ssl_opts(%{"verify" => "verify_none", "versions" => ["tlsv1.3"]})
      [verify: :verify_none, versions: ['tlsv1.3']]

      iex> FzCommon.dump_ssl_opts(%{"keep_secrets" => true})
      ** (ArgumentError) unsupported key keep_secrets in ssl opts

      iex> FzCommon.dump_ssl_opts(%{"cacertfile" => "/tmp/cacerts.pem"})
      [cacertfile: '/tmp/cacerts.pem']
  """
  def dump_ssl_opts(decoded_json) do
    Keyword.new(decoded_json, fn {k, v} ->
      {String.to_atom(k), map_values(k, v)}
    end)
  end

  defp map_values("verify", v), do: String.to_atom(v)
  defp map_values("versions", v), do: Enum.map(v, &String.to_charlist/1)
  defp map_values("cacertfile", v), do: String.to_charlist(v)
  defp map_values("server_name_indication", v), do: String.to_charlist(v)
  defp map_values(k, _v), do: raise(ArgumentError, message: "unsupported key #{k} in ssl opts")

  def keyword(enum) do
    Keyword.new(enum, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  end
end
