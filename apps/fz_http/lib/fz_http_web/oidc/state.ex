defmodule FzHttpWeb.OIDC.State do
  @moduledoc """
  Helpers to manage the OIDC CSRF token, otherwise known as the state param,
  throughout the login flow.
  """
  @oidc_state_key "fz_oidc_state"
  @oidc_state_valid_duration 300

  import Plug.Conn

  def put_cookie(conn, state) do
    put_resp_cookie(conn, @oidc_state_key, state, cookie_opts())
  end

  def fetch_and_verify_state(conn, state) do
    conn
    |> fetch_cookies(signed: [@oidc_state_key])
    |> then(fn
      %{cookies: %{@oidc_state_key => ^state}} ->
        client_params =
          state
          |> Base.decode64!(padding: false)
          |> :erlang.binary_to_term([:safe])
          |> Map.get(:client_params, %{})

        {:ok, client_params}

      _ ->
        {:error, "Cannot verify state"}
    end)
  end

  def new(client_params \\ %{}) do
    %{
      state: FzHttp.Crypto.rand_string(),
      client_params: client_params
    }
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  defp cookie_opts do
    [
      max_age: @oidc_state_valid_duration,
      sign: true,
      same_site: "Lax",
      secure: FzHttp.Config.fetch_env!(:fz_http, :cookie_secure)
    ]
  end
end
