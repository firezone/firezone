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

  def find_or_create(_provider, %{"email" => email, "sub" => _sub}) do
    case Users.get_by_email(email) do
      nil -> maybe_create_user(email)
      user -> {:ok, user}
    end
  end

  defp maybe_create_user(email) do
    if FzHttp.Conf.get(:auto_create_oidc_users) do
      Users.create_unprivileged_user(%{email: email})
    else
      {:error, "not found"}
    end
  end
end
