defmodule PortalWeb.Cookie.AuthenticationState do
  @moduledoc """
  Cookie for storing OIDC sign-in auth state.
  Contains only our own generated data — never provider-returned values.
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

  @cookie_key "oidc"

  def put(conn, %__MODULE__{} = cookie) do
    Plug.Conn.put_resp_cookie(conn, @cookie_key, to_binary(cookie), cookie_options())
  end

  def fetch(conn) do
    conn = Plug.Conn.fetch_cookies(conn, signed: [@cookie_key])
    from_binary(conn.cookies[@cookie_key])
  end

  def delete(conn) do
    Plug.Conn.delete_resp_cookie(conn, @cookie_key, cookie_options())
  end

  defp cookie_options do
    [
      sign: true,
      max_age: 5 * 60,
      same_site: "Lax",
      secure: Portal.Config.fetch_env!(:portal, :cookie_secure),
      http_only: true,
      signing_salt: Portal.Config.fetch_env!(:portal, :cookie_signing_salt)
    ]
  end

  defp to_binary(%__MODULE__{} = cookie) do
    account_id_bytes = Ecto.UUID.dump!(cookie.account_id)
    provider_id_bytes = Ecto.UUID.dump!(cookie.auth_provider_id)

    {
      cookie.auth_provider_type,
      provider_id_bytes,
      account_id_bytes,
      cookie.account_slug,
      cookie.state,
      cookie.verifier,
      cookie.params
    }
    |> :erlang.term_to_binary()
  end

  defp from_binary(binary) when is_binary(binary) do
    case safe_binary_to_term(binary) do
      {auth_provider_type, provider_id_bytes, account_id_bytes, account_slug, state, verifier,
       params} ->
        with {:ok, provider_id} <- Ecto.UUID.load(provider_id_bytes),
             {:ok, account_id} <- Ecto.UUID.load(account_id_bytes) do
          %__MODULE__{
            auth_provider_type: auth_provider_type,
            auth_provider_id: provider_id,
            account_id: account_id,
            account_slug: account_slug,
            state: state,
            verifier: verifier,
            params: params
          }
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp from_binary(_), do: nil

  # sobelow_skip ["Misc.BinToTerm"]
  defp safe_binary_to_term(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    _ -> :error
  end
end
