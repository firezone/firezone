defmodule Web.Settings.IdentityProviders.IndexNew do
  @moduledoc """
    The new identity provider settings UI for accounts that have migrated to the new authentication system.
  """

  use Web, :live_view

  alias Domain.{
    EmailOTP,
    Userpass,
    OIDC,
    Entra,
    Google,
    Okta
  }

  def mount(_params, _session, socket) do
    auth_providers = auth_providers(socket.assigns.account)
    directories = directories(socket.assigns.account)

    {:ok, assign(socket, auth_providers: auth_providers, directories: directories)}
  end

  def handle_event("new_identity_provider", _params, socket) do
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div>
      <h1>Identity Providers</h1>
      <hr />
      <h2>Authentication Providers</h2>
      <button phx-click="new_identity_provider">Add Identity Provider</button>
      <ul>
        <%= for provider <- @auth_providers.email_otp do %>
          <li>{provider.name}</li>
        <% end %>
      </ul>
      <ul>
        <%= for provider <- @auth_providers.userpass do %>
          <li>{provider.name}</li>
        <% end %>
      </ul>
      <ul>
        <%= for provider <- @auth_providers.oidc do %>
          <li>{provider.name}</li>
        <% end %>
      </ul>
      <ul>
        <%= for provider <- @auth_providers.entra do %>
          <li>{provider.name}</li>
        <% end %>
      </ul>
      <ul>
        <%= for provider <- @auth_providers.google do %>
          <li>{provider.name}</li>
        <% end %>
      </ul>
      <ul>
        <%= for provider <- @auth_providers.okta do %>
          <li>{provider.name}</li>
        <% end %>
      </ul>
      <h2>Directories</h2>
      <ul>
        <%= for directory <- @directories.entra_directories do %>
          <li>{directory.name}</li>
        <% end %>
      </ul>
      <ul>
        <%= for directory <- @directories.google_directories do %>
          <li>{directory.name}</li>
        <% end %>
      </ul>
      <ul>
        <%= for directory <- @directories.okta_directories do %>
          <li>{directory.name}</li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp auth_providers(account) do
    %{
      email_otp: EmailOTP.all_auth_providers_for_account!(account),
      userpass: Userpass.all_auth_providers_for_account!(account),
      oidc: OIDC.all_auth_providers_for_account!(account),
      entra: Entra.all_auth_providers_for_account!(account),
      google: Google.all_auth_providers_for_account!(account),
      okta: Okta.all_auth_providers_for_account!(account)
    }
  end

  defp directories(account) do
    %{
      entra_directories: Entra.all_directories_for_account!(account),
      google_directories: Google.all_directories_for_account!(account),
      okta_directories: Okta.all_directories_for_account!(account)
    }
  end
end
