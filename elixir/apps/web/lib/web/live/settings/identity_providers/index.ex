defmodule Web.Settings.IdentityProviders.Index do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.{Auth, Actors}

  def mount(_params, _session, socket) do
    subject = socket.assigns.subject

    with {:ok, providers} <- Auth.list_providers(subject),
         {:ok, identities_count_by_provider_id} <-
           Auth.fetch_identities_count_grouped_by_provider_id(subject),
         {:ok, groups_count_by_provider_id} <-
           Actors.fetch_groups_count_grouped_by_provider_id(subject) do
      socket =
        assign(socket,
          identities_count_by_provider_id: identities_count_by_provider_id,
          groups_count_by_provider_id: groups_count_by_provider_id,
          providers: providers,
          page_title: "Identity Providers"
        )

      {:ok, socket}
    else
      _ -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Identity Providers
      </:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/settings/identity_providers/new"}>
          Add Identity Provider
        </.add_button>
      </:action>
      <:help>
        <.link
          class={link_style()}
          href="https://www.firezone.dev/kb/authenticate?utm_source=product"
          target="_blank"
        >
          Read more about how authentication works in Firezone.
        </.link>
      </:help>
      <:content>
        <.flash_group flash={@flash} />
        <div class="bg-white overflow-hidden">
          <.table id="providers" rows={@providers} row_id={&"providers-#{&1.id}"}>
            <:col :let={provider} label="Name">
              <.link navigate={view_provider(@account, provider)} class={[link_style()]}>
                <%= provider.name %>
              </.link>
            </:col>
            <:col :let={provider} label="Type"><%= adapter_name(provider.adapter) %></:col>
            <:col :let={provider} label="Status">
              <.status provider={provider} />
            </:col>
            <:col :let={provider} label="Sync Status">
              <.sync_status
                account={@account}
                provider={provider}
                identities_count_by_provider_id={@identities_count_by_provider_id}
                groups_count_by_provider_id={@groups_count_by_provider_id}
              />
            </:col>
            <:empty>
              <div class="flex justify-center text-center text-neutral-500 p-4">
                <div class="w-auto">
                  <div class="pb-4">
                    No identity providers to display
                  </div>
                  <.add_button navigate={~p"/#{@account}/settings/identity_providers/new"}>
                    Add Identity Provider
                  </.add_button>
                </div>
              </div>
            </:empty>
          </.table>
        </div>
      </:content>
    </.section>
    """
  end
end
