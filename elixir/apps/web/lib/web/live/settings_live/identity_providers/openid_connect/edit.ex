defmodule Web.SettingsLive.IdentityProviders.OpenIDConnect.Edit do
  use Web, :live_view
  import Web.SettingsLive.IdentityProviders.OpenIDConnect.Components
  alias Domain.Auth

  def mount(%{"provider_id" => provider_id}, _session, socket) do
    with {:ok, provider} <- Domain.Auth.fetch_provider_by_id(provider_id, socket.assigns.subject) do
      changeset = Auth.change_provider(provider)

      socket =
        assign(socket,
          provider: provider,
          form: to_form(changeset)
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_event("change", %{"provider" => attrs}, socket) do
    changeset =
      Auth.change_provider(socket.assigns.provider, attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"provider" => attrs}, socket) do
    with {:ok, provider} <-
           Auth.update_provider(socket.assigns.provider, attrs, socket.assigns.subject) do
      socket =
        redirect(socket,
          to:
            ~p"/#{socket.assigns.account}/settings/identity_providers/google_workspace/#{provider}/redirect"
        )

      {:noreply, socket}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
      <.breadcrumb path={
        ~p"/#{@account}/settings/identity_providers/google_workspace/#{@form.data}/edit"
      }>
        Edit <%= # {@form.data.name} %>
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Edit Identity Provider <%= @form.data.name %>
      </:title>
    </.header>
    <section class="bg-white dark:bg-gray-900">
      <.provider_form account={@account} id={@form.data.id} form={@form} />
    </section>
    """
  end
end
