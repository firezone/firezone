defmodule FzHttpWeb.Authentication do
  @moduledoc """
  Authentication helpers.
  """
  use Guardian, otp_app: :fz_http

  alias FzHttp.Telemetry
  alias FzHttp.Users
  alias FzHttp.Users.User
  alias FzHttpWeb.Router.Helpers, as: Routes

  import Phoenix.Controller

  import Plug.Conn,
    only: [
      halt: 1,
      put_session: 3
    ]

  @guardian_token_name "guardian_default_token"

  def subject_for_token(resource, _claims) do
    {:ok, to_string(resource.id)}
  end

  def resource_from_claims(%{"sub" => id}) do
    case Users.get_user(id) do
      nil -> {:error, :resource_not_found}
      user -> {:ok, user}
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

  def sign_in(conn, user, %{provider: provider} = auth) do
    if !Application.fetch_env!(:fz_http, :local_auth_enabled) &&
         provider in [:identity, :magic_link] do
      conn
      |> sign_out()
      |> put_flash(:error, "Local auth disabled.")
      |> redirect(to: Routes.root_path(conn, :index))
      |> halt()
    else
      conn =
        with :identity <- provider,
             true <- FzHttp.MFA.exists?(user) do
          put_session(conn, :mfa_required_at, DateTime.utc_now())
        else
          _ -> conn
        end

      Telemetry.login()
      Users.update_last_signed_in(user, auth)

      __MODULE__.Plug.sign_in(conn, user)
    end
  end

  def sign_out(conn) do
    __MODULE__.Plug.sign_out(conn)
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
