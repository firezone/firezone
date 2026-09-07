defmodule PortalWeb.SignUpController do
  use PortalWeb, :controller

  alias PortalWeb.Cookie

  require Logger

  @unavailable_error "Google sign-in is unavailable right now. Please try again later or sign up with email."

  @spec google(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google(conn, _params) do
    state_type = PortalWeb.OIDC.verification_state_type("google_sign_up")

    with {:ok, %{config: config}} <- PortalWeb.OIDC.setup_verification("google_sign_up", []),
         verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false),
         state = PortalWeb.OIDC.sign_verification_state(nil, state_type),
         {:ok, uri} <-
           PortalWeb.OIDC.build_verification_uri("google_sign_up", config, verifier, state) do
      conn
      |> Cookie.SignUpState.put(%Cookie.SignUpState{state: state, verifier: verifier})
      |> redirect(external: uri)
    else
      {:error, reason} ->
        Logger.warning("Google sign-up authorization URI error", reason: inspect(reason))

        conn
        |> put_flash(:error, @unavailable_error)
        |> redirect(to: ~p"/sign_up")
    end
  end
end
