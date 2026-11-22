defmodule PortalWeb.Cookie.OAuthClient do
  @moduledoc """
  Cookie naming the app an authorization request is for, so the sign-in page
  can show it without fetching the client's metadata document again.

  Written by the authorization endpoint after it has fetched and checked that
  document. It holds only what the sign-in page shows: the client ID, the name
  and the addresses the document was served from. The icon is left out to keep
  the cookie small.
  """

  @cookie_key "oauth_client"
  @max_bytes 2048
  @cookie_options [
    sign: true,
    max_age: 15 * 60,
    same_site: "Lax",
    secure: Portal.Config.fetch_env!(:portal, :cookie_secure),
    http_only: true,
    signing_salt: Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
  ]

  def put(conn, %Portal.OAuthClient{} = client) do
    binary = to_binary(client)

    if byte_size(binary) <= @max_bytes do
      Plug.Conn.put_resp_cookie(conn, @cookie_key, binary, @cookie_options)
    else
      Plug.Conn.delete_resp_cookie(conn, @cookie_key, @cookie_options)
    end
  end

  @doc """
  Returns the client stored for `client_id`, or nil when the cookie is missing,
  invalid, or names a different client.
  """
  def fetch(conn, client_id) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@cookie_key])

    case from_binary(conn.cookies[@cookie_key]) do
      %Portal.OAuthClient{client_id: ^client_id} = client -> client
      _other -> nil
    end
  end

  defp to_binary(%Portal.OAuthClient{} = client) do
    addresses = Enum.map(client.resolved_ips, & &1.address)
    :erlang.term_to_binary({client.client_id, client.client_name, addresses})
  end

  # sobelow_skip ["Misc.BinToTerm"]
  defp from_binary(binary) when is_binary(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      {client_id, client_name, addresses}
      when is_binary(client_id) and is_binary(client_name) and is_list(addresses) ->
        true = Enum.all?(addresses, &:inet.is_ip_address/1)

        %Portal.OAuthClient{
          client_id: client_id,
          client_name: client_name,
          resolved_ips: Enum.map(addresses, &%Postgrex.INET{address: &1})
        }
    end
  rescue
    _ -> nil
  end

  defp from_binary(_binary), do: nil
end
