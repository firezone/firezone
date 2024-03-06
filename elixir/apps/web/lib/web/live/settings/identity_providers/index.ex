defmodule Web.Settings.IdentityProviders.Index do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.{Auth, Actors}

  def mount(_params, _session, socket) do
    with {:ok, identities_count_by_provider_id} <-
           Auth.fetch_identities_count_grouped_by_provider_id(socket.assigns.subject),
         {:ok, groups_count_by_provider_id} <-
           Actors.fetch_groups_count_grouped_by_provider_id(socket.assigns.subject) do
      sortable_fields = [
        {:providers, :name}
      ]

      {:ok,
       assign(socket,
         page_title: "Identity Providers",
         sortable_fields: sortable_fields,
         identities_count_by_provider_id: identities_count_by_provider_id,
         groups_count_by_provider_id: groups_count_by_provider_id
       )}
    else
      _ -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    {socket, list_opts} =
      handle_rich_table_params(params, uri, socket, "providers", Auth.Provider.Query)

    with {:ok, providers, metadata} <- Auth.list_providers(socket.assigns.subject, list_opts) do
      socket =
        assign(socket,
          providers: providers,
          metadata: metadata
        )

      {:noreply, socket}
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
        <.website_link href="/kb/authenticate">
          Read more
        </.website_link>
        about how authentication works in Firezone.
      </:help>
      <:content>
        <.flash_group flash={@flash} />
        <div class="bg-white overflow-hidden">
          <.rich_table
            id="providers"
            rows={@providers}
            row_id={&"providers-#{&1.id}"}
            sortable_fields={@sortable_fields}
            filters={@filters}
            filter={@filter}
            metadata={@metadata}
          >
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
          </.rich_table>
        </div>
      </:content>
    </.section>
    """
  end
end
