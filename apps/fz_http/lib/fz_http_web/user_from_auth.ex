defmodule FzHttpWeb.UserFromAuth do
  @moduledoc """
  Authenticates users.
  """

  alias FzHttp.Configurations, as: Conf
  alias FzHttp.Users
  alias FzHttpWeb.Auth.HTML.Authentication

  def find_or_create(
        %Ueberauth.Auth{
          provider: :identity,
          info: %Ueberauth.Auth.Info{email: email},
          credentials: %Ueberauth.Auth.Credentials{other: %{password: password}}
        } = _auth
      ) do
    Users.get_by_email(email) |> Authentication.authenticate(password)
  end

  # SAML
  def find_or_create(:saml, provider_key, %{"email" => email}) do
    case Users.get_by_email(email) do
      nil -> maybe_create_user(:saml_identity_providers, provider_key, email)
      user -> {:ok, user}
    end
  end

  # OIDC
  def find_or_create(provider_key, %{"email" => email, "sub" => _sub}) do
    case Users.get_by_email(email) do
      nil -> maybe_create_user(:openid_connect_providers, provider_key, email)
      user -> {:ok, user}
    end
  end

  defp maybe_create_user(idp_field, provider_key, email) do
    if Conf.auto_create_users?(idp_field, provider_key) do
      Users.create_unprivileged_user(%{email: email})
    else
      {:error, "not found"}
    end
  end
end
