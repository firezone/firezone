defmodule FzHttpWeb.Authentication do
  @moduledoc """
  Authentication helpers.
  """
  use Guardian, otp_app: :fz_http

  alias FzHttp.Telemetry
  alias FzHttp.Users
  alias FzHttp.Users.User

  def subject_for_token(resource, _claims) do
    {:ok, to_string(resource.id)}
  end

  def resource_from_claims(%{"sub" => id}) do
    case Users.get_user(id) do
      nil -> {:error, :resource_not_found}
      user -> {:ok, user}
    end
  end

  def authenticate(%User{} = user, password) do
    authenticate(
      user,
      password,
      Argon2.verify_pass(password, user.password_hash)
    )
  end

  def authenticate(nil, password) do
    authenticate(nil, password, Argon2.no_user_verify())
  end

  defp authenticate(user, _password, true) do
    {:ok, user}
  end

  defp authenticate(_user, _password, false) do
    {:error, :invalid_credentials}
  end

  def sign_in(conn, user) do
    # XXX: Put user socket id into session
    Telemetry.login(user)
    Users.update_last_signed_in(user)
    __MODULE__.Plug.sign_in(conn, user)
  end

  def sign_out(conn) do
    __MODULE__.Plug.sign_out(conn)
  end

  def get_current_user(conn) do
    __MODULE__.Plug.current_resource(conn)
  end
end
