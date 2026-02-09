defmodule PortalWeb.Cookie.ClientAuth do
  @moduledoc """
  Cookie for client authentication redirect state.
  """

  @enforce_keys [:actor_name, :fragment, :identity_provider_identifier]
  defstruct [:actor_name, :fragment, :identity_provider_identifier, :state]

  @type t :: %__MODULE__{
          actor_name: String.t(),
          fragment: String.t(),
          identity_provider_identifier: String.t(),
          state: String.t() | nil
        }

  @cookie_key "client_auth"
  @cookie_options [
    sign: true,
    max_age: 2 * 60,
    same_site: "Lax",
    secure: Portal.Config.fetch_env!(:portal, :cookie_secure),
    http_only: true,
    signing_salt: Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
  ]

  def put(conn, %__MODULE__{} = cookie) do
    Plug.Conn.put_resp_cookie(conn, @cookie_key, to_binary(cookie), @cookie_options)
  end

  def fetch(conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@cookie_key])
    from_binary(conn.cookies[@cookie_key])
  end

  defp to_binary(%__MODULE__{} = cookie) do
    {cookie.actor_name, cookie.fragment, cookie.identity_provider_identifier, cookie.state}
    |> :erlang.term_to_binary()
  end

  # sobelow_skip ["Misc.BinToTerm"]
  defp from_binary(binary) when is_binary(binary) do
    {actor_name, fragment, identity_provider_identifier, state} =
      :erlang.binary_to_term(binary, [:safe])

    %__MODULE__{
      actor_name: actor_name,
      fragment: fragment,
      identity_provider_identifier: identity_provider_identifier,
      state: state
    }
  rescue
    _ -> nil
  end

  defp from_binary(_), do: nil
end
