defmodule FzHttpWeb.UserFromAuth do
  @moduledoc """
  Authenticates users.
  """
  alias FzHttp.{Auth, Users}
  alias FzHttpWeb.Auth.HTML.Authentication

  # Local auth
  def find_or_create(
        %Ueberauth.Auth{
          provider: :identity,
          info: %Ueberauth.Auth.Info{email: email},
          credentials: %Ueberauth.Auth.Credentials{other: %{password: password}}
        } = _auth
      ) do
    with {:ok, user} <- Users.fetch_user_by_email(email) do
      Authentication.authenticate(user, password)
    end
  end

  # SAML
  def find_or_create(:saml, provider_id, %{"email" => email}) do
    with {:ok, user} <- Users.fetch_user_by_email(email) do
      {:ok, user}
    else
      {:error, :not_found} -> maybe_create_user(:saml_identity_providers, provider_id, email)
    end
  end

  # OIDC
  def find_or_create(provider_id, %{"email" => email, "sub" => _sub}) do
    with {:ok, user} <- Users.fetch_user_by_email(email) do
      {:ok, user}
    else
      {:error, :not_found} -> maybe_create_user(:openid_connect_providers, provider_id, email)
    end
  end

  defp maybe_create_user(idp_field, provider_id, email) do
    if Auth.auto_create_users?(idp_field, provider_id) do
      Users.create_unprivileged_user(%{email: email})
    else
      {:error, "user not found and auto_create_users disabled"}
    end
  end
end
