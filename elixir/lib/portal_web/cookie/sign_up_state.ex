defmodule PortalWeb.Cookie.SignUpState do
  @moduledoc """
  Cookie that binds a Google sign-up round trip to the browser that started it.
  Holds only the OAuth state and the PKCE verifier we generated.
  """

  @enforce_keys [:state, :verifier]
  defstruct [:state, :verifier]

  @cookie_key "sign_up_oidc"

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
    :erlang.term_to_binary({cookie.state, cookie.verifier})
  end

  defp from_binary(binary) when is_binary(binary) do
    case safe_binary_to_term(binary) do
      {state, verifier} when is_binary(state) and is_binary(verifier) ->
        %__MODULE__{state: state, verifier: verifier}

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
