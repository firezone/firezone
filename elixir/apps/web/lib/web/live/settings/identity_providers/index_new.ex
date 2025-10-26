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

  require Logger

  def mount(_params, _session, socket) do
    auth_providers = auth_providers(socket.assigns.account)
    directories = directories(socket.assigns.account)

    {:ok,
     assign(socket,
       auth_providers: auth_providers,
       directories: directories,
       provider: nil,
       directory: nil
     )}
  end

  def handle_params(
        %{"provider_id" => provider_id},
        _url,
        %{assigns: %{live_action: live_action}} = socket
      ) do
    provider =
      case live_action do
        :edit_email_otp_auth_provider ->
          case EmailOTP.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_userpass_auth_provider ->
          case Userpass.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_oidc_auth_provider ->
          case OIDC.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_google_auth_provider ->
          case Google.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_entra_auth_provider ->
          case Entra.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_okta_auth_provider ->
          case Okta.fetch_auth_provider_by_id(provider_id, socket.assigns.subject) do
            {:ok, provider} -> provider
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        _ ->
          raise Web.LiveErrors.NotFoundError
      end

    {:noreply, assign(socket, provider: provider, directory: nil)}
  end

  def handle_params(
        %{"directory_id" => directory_id},
        _url,
        %{assigns: %{live_action: live_action}} = socket
      ) do
    directory =
      case live_action do
        :edit_google_directory ->
          case Google.fetch_directory_by_id(directory_id, socket.assigns.subject) do
            {:ok, directory} -> directory
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_entra_directory ->
          case Entra.fetch_directory_by_id(directory_id, socket.assigns.subject) do
            {:ok, directory} -> directory
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        :edit_okta_directory ->
          case Okta.fetch_directory_by_id(directory_id, socket.assigns.subject) do
            {:ok, directory} -> directory
            {:error, _} -> raise Web.LiveErrors.NotFoundError
          end

        _ ->
          raise Web.LiveErrors.NotFoundError
      end

    {:noreply, assign(socket, provider: nil, directory: directory)}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, provider: nil, directory: nil)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/identity_providers")}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>Identity Providers</:title>
      <:action><.docs_action path="/guides/settings/identity-providers" /></:action>
      <:help>
        Identity providers authenticate and sync your users and groups with an external source.
      </:help>
      <:content>
        {# TODO: Show summary info?}
      </:content>
    </.section>
    <.section>
      <:title>Authentication Providers</:title>
      <:action>
        <.add_button patch={~p"/#{@account}/settings/identity_providers/auth_providers/new"}>
          Add Provider
        </.add_button>
      </:action>
      <:content>
        <%= for provider <- @auth_providers.email_otp do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/email_otp_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.userpass do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/userpass_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.oidc do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/oidc_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.google do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/google_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.entra do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/entra_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
        <%= for provider <- @auth_providers.okta do %>
          <.auth_provider_item
            provider={provider}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/okta_auth_providers/#{provider}/edit"
            }
          />
        <% end %>
      </:content>
    </.section>
    <.section>
      <:title>Directories</:title>
      <:action>
        <.add_button patch={~p"/#{@account}/settings/identity_providers/directories/new"}>
          Add Directory
        </.add_button>
      </:action>
      <:content>
        <%= for directory <- @directories.google_directories do %>
          <.directory_item
            directory={directory}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/google_directories/#{directory}/edit"
            }
          />
        <% end %>
        <%= for directory <- @directories.entra_directories do %>
          <.directory_item
            directory={directory}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/entra_directories/#{directory}/edit"
            }
          />
        <% end %>
        <%= for directory <- @directories.okta_directories do %>
          <.directory_item
            directory={directory}
            edit_path={
              ~p"/#{@account}/settings/identity_providers/okta_directories/#{directory}/edit"
            }
          />
        <% end %>
      </:content>
    </.section>

    <.modal
      :if={@live_action == :new_auth_provider}
      id="new-auth-provider-modal"
      show={true}
      on_close="close_modal"
    >
      <:title>Add Authentication Provider</:title>
      <:body>
        <p>Select an authentication provider type to add:</p>
        <form>
          <ul class="grid w-full gap-6 grid-cols-1">
            <li>
              <.input
                id="provider-type--google"
                type="radio_button_group"
                name="provider_type"
                value="google"
                checked={false}
                required
              />
              <label for="provider-type--google" class={~w[
                component bg-white rounded p-4 flex items-center
                cursor-pointer hover:bg-neutral-50
                border border-neutral-300 hover:border-neutral-900
              ]}>
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:google} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    Google
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against a Google Workspace account.
                </span>
              </label>
            </li>
            <li>
              <.input
                id="provider-type--entra"
                type="radio_button_group"
                name="provider_type"
                value="entra"
                checked={false}
                required
              />
              <label for="provider-type--entra" class={~w[
                component bg-white rounded p-4 flex items-center
                cursor-pointer hover:bg-neutral-50
                border border-neutral-300 hover:border-neutral-900
              ]}>
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:entra} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    Entra
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against a Microsoft Entra account.
                </span>
              </label>
            </li>
            <li>
              <.input
                id="provider-type--okta"
                type="radio_button_group"
                name="provider_type"
                value="okta"
                checked={false}
                required
              />
              <label for="provider-type--okta" class={~w[
                component bg-white rounded p-4 flex items-center
                cursor-pointer hover:bg-neutral-50
                border border-neutral-300 hover:border-neutral-900
              ]}>
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:okta} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    Okta
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against an Okta account.
                </span>
              </label>
            </li>
            <li>
              <.input
                id="provider-type--oidc"
                type="radio_button_group"
                name="provider_type"
                value="oidc"
                checked={false}
                required
              />
              <label for="provider-type--oidc" class={~w[
                component bg-white rounded p-4 flex items-center
                cursor-pointer hover:bg-neutral-50
                border border-neutral-300 hover:border-neutral-900
              ]}>
                <span class="w-1/3 flex items-center">
                  <.provider_icon type={:oidc} class="w-10 h-10 inline-block mr-2" />
                  <span class="font-medium">
                    OpenID Connect
                  </span>
                </span>
                <span class="w-2/3">
                  Authenticate users against an OpenID Connect compliant identity provider.
                </span>
              </label>
            </li>
          </ul>
        </form>
      </:body>
    </.modal>

    <.modal
      :if={@live_action == :new_directory}
      id="new-directory-modal"
      show={true}
      on_close="close_modal"
    >
      <:title>Add Directory Provider</:title>
      <:body>
        <p>Select a directory provider type to add:</p>
        {# TODO: Add directory provider selection UI }
      </:body>
    </.modal>

    <.modal
      :if={
        @live_action in [
          :edit_email_otp_auth_provider,
          :edit_userpass_auth_provider,
          :edit_oidc_auth_provider,
          :edit_google_auth_provider,
          :edit_entra_auth_provider,
          :edit_okta_auth_provider
        ] && @provider
      }
      id="edit-auth-provider-modal"
      show={true}
      on_close="close_modal"
    >
      <:title>Edit {@provider.name}</:title>
      <:body>
        <p>Edit authentication provider form will go here</p>
        {# TODO: Add provider edit form }
      </:body>
    </.modal>

    <.modal
      :if={
        @live_action in [:edit_google_directory, :edit_entra_directory, :edit_okta_directory] &&
          @directory
      }
      id="edit-directory-modal"
      show={true}
      on_close="close_modal"
    >
      <:title>Edit {@directory.name}</:title>
      <:body>
        <p>Edit directory provider form will go here</p>
        {# TODO: Add directory edit form }
      </:body>
    </.modal>
    """
  end

  defp auth_provider_item(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-2 border-b">
      <span>{@provider.name}</span>
      <.button size="xs" icon="hero-pencil" patch={@edit_path}>
        Edit
      </.button>
    </div>
    """
  end

  defp directory_item(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-2 border-b">
      <span>{@directory.name}</span>
      <.button size="xs" icon="hero-pencil" patch={@edit_path}>
        Edit
      </.button>
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
