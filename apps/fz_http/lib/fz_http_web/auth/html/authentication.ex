defmodule FzHttpWeb.Auth.HTML.Authentication do
  @moduledoc """
  HTML Authentication implementation module for Guardian.
  """
  use Guardian, otp_app: :fz_http
  use FzHttpWeb, :controller

  alias FzHttp.Telemetry
  alias FzHttp.Users
  alias FzHttp.Users.User

  import FzHttpWeb.OIDC.Helpers

  require Logger

  @guardian_token_name "guardian_default_token"

  @impl Guardian
  def subject_for_token(resource, _claims) do
    {:ok, resource.id}
  end

  @impl Guardian
  def resource_from_claims(%{"sub" => id}) do
    case Users.fetch_user_by_id(id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:error, :resource_not_found}
    end
  end

  @doc """
  Authenticates a user against a password hash. Only makes sense
  for local auth.
  """
  def authenticate(%User{} = user, password) when is_binary(password) do
    if user.password_hash do
      authenticate(
        user,
        password,
        Argon2.verify_pass(password, user.password_hash)
      )
    else
      {:error, :invalid_credentials}
    end
  end

  def authenticate(_user, _password) do
    authenticate(nil, nil, Argon2.no_user_verify())
  end

  defp authenticate(user, _password, true) do
    {:ok, user}
  end

  defp authenticate(_user, _password, false) do
    {:error, :invalid_credentials}
  end

  def sign_in(conn, user, auth) do
    Telemetry.login()
    Users.update_last_signed_in(user, auth)
    %{provider: provider_id} = auth

    conn =
      with :identity <- provider_id,
           true <- FzHttp.MFA.exists?(user) do
        Plug.Conn.put_session(conn, "mfa_required_at", DateTime.utc_now())
      else
        _ -> conn
      end
      # XXX: OIDC and SAML provider IDs can be strings, so normalize to string here
      |> Plug.Conn.put_session("login_method", to_string(provider_id))

    __MODULE__.Plug.sign_in(conn, user)
  end

  def sign_out(conn) do
    with provider_id when not is_nil(provider_id) <- Plug.Conn.get_session(conn, "login_method"),
         provider when not is_nil(provider) <-
           FzHttp.Configurations.get_provider_by_id(:openid_connect_providers, provider_id),
         token when not is_nil(token) <- Plug.Conn.get_session(conn, "id_token"),
         end_session_uri when not is_nil(end_session_uri) <-
           openid_connect().end_session_uri(provider_id, %{
             client_id: provider.client_id,
             id_token_hint: token,
             post_logout_redirect_uri: url(~p"/")
           }) do
      conn
      |> __MODULE__.Plug.sign_out()
      |> Plug.Conn.configure_session(drop: true)
      |> Phoenix.Controller.redirect(external: end_session_uri)
    else
      _ ->
        conn
        |> __MODULE__.Plug.sign_out()
        |> Plug.Conn.configure_session(drop: true)
        |> Phoenix.Controller.redirect(to: ~p"/")
    end
  end

  def get_current_user(%Plug.Conn{} = conn) do
    __MODULE__.Plug.current_resource(conn)
  end

  def get_current_user(%{@guardian_token_name => token} = _session) do
    case Guardian.resource_from_token(__MODULE__, token) do
      {:ok, resource, _claims} ->
        resource

      {:error, _reason} ->
        nil
    end
  end
end
