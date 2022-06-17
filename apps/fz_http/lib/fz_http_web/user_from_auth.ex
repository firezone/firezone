defmodule FzHttpWeb.UserFromAuth do
  @moduledoc """
  Authenticates users.
  """

  alias FzHttp.Users
  alias FzHttpWeb.Authentication
  alias Ueberauth.Auth

  def find_or_create(
        %Auth{
          provider: :identity,
          info: %Auth.Info{email: email},
          credentials: %Auth.Credentials{other: %{password: password}}
        } = _auth
      ) do
    Users.get_by_email(email) |> Authentication.authenticate(password)
  end

  def find_or_create(%Auth{provider: provider, info: %Auth.Info{email: email}} = _auth)
      when provider in [:google, :okta] do
    case Users.get_by_email(email) do
      nil -> maybe_create_user(auto_create_oidc_users?(), email)
      user -> {:ok, user}
    end
  end

  def find_or_create(_provider, %{"email" => email, "sub" => _sub}) do
    case Users.get_by_email(email) do
      nil -> maybe_create_user(auto_create_oidc_users?(), email)
      user -> {:ok, user}
    end
  end

  defp maybe_create_user(true, email) do
    Users.create_unprivileged_user(%{email: email})
  end

  defp maybe_create_user(false, _email) do
    {:error, "not found"}
  end

  defp auto_create_oidc_users? do
    Application.fetch_env!(:fz_http, :auto_create_oidc_users)
  end
end
