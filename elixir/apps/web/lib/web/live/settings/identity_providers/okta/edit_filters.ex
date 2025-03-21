defmodule Web.Settings.IdentityProviders.Okta.EditFilters do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.Auth

  def mount(%{"provider_id" => provider_id}, _session, socket) do
    with {:ok, provider} <- Auth.fetch_provider_by_id(provider_id, socket.assigns.subject) do
      socket =
        assign(socket,
          provider: provider,
          page_title: "Edit #{provider.name}"
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers/okta/#{@provider}/edit"}>
        Edit
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Edit Identity Provider {@provider}
      </:title>
      <:content></:content>
    </.section>
    """
  end

  # For group filters

  def handle_event(event, params, socket),
    do: handle_group_filters_event(event, params, socket)
end
