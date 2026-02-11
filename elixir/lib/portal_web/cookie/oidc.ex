defmodule PortalWeb.Cookie.OIDC do
  @moduledoc """
  Cookie for OIDC authentication state.
  """

  @enforce_keys [
    :auth_provider_type,
    :auth_provider_id,
    :account_id,
    :account_slug,
    :state,
    :verifier
  ]
  defstruct [
    :auth_provider_type,
    :auth_provider_id,
    :account_id,
    :account_slug,
    :state,
    :verifier,
    :params
  ]

  @type t :: %__MODULE__{
          auth_provider_type: String.t(),
          auth_provider_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          account_slug: String.t(),
          state: String.t(),
          verifier: String.t(),
          params: map() | nil
        }

  @cookie_key "oidc"
  @cookie_options [
    sign: true,
    max_age: 5 * 60,
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

  def delete(conn) do
    Plug.Conn.delete_resp_cookie(conn, @cookie_key, @cookie_options)
  end

  defp to_binary(%__MODULE__{} = cookie) do
    {
      cookie.auth_provider_type,
      Ecto.UUID.dump!(cookie.auth_provider_id),
      Ecto.UUID.dump!(cookie.account_id),
      cookie.account_slug,
      cookie.state,
      cookie.verifier,
      cookie.params
    }
    |> :erlang.term_to_binary()
  end

  # sobelow_skip ["Misc.BinToTerm"]
  defp from_binary(binary) when is_binary(binary) do
    {auth_provider_type, auth_provider_id, account_id, account_slug, state, verifier, params} =
      :erlang.binary_to_term(binary, [:safe])

    %__MODULE__{
      auth_provider_type: auth_provider_type,
      auth_provider_id: Ecto.UUID.load!(auth_provider_id),
      account_id: Ecto.UUID.load!(account_id),
      account_slug: account_slug,
      state: state,
      verifier: verifier,
      params: params
    }
  rescue
    _ -> nil
  end

  defp from_binary(_), do: nil
end
