defmodule Web.Settings.IdentityProviders.Index do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.{Auth, Actors}

  def mount(_params, _session, socket) do
    with {:ok, identities_count_by_provider_id} <-
           Auth.fetch_identities_count_grouped_by_provider_id(socket.assigns.subject),
         {:ok, groups_count_by_provider_id} <-
           Actors.fetch_groups_count_grouped_by_provider_id(socket.assigns.subject) do
      socket =
        socket
        |> assign(
          page_title: "Identity Providers",
          identities_count_by_provider_id: identities_count_by_provider_id,
          groups_count_by_provider_id: groups_count_by_provider_id
        )
        |> assign_live_table("providers",
          query_module: Auth.Provider.Query,
          sortable_fields: [
            {:providers, :name}
          ],
          callback: &handle_providers_update!/2
        )

      {:ok, socket}
    else
      _ -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_providers_update!(socket, list_opts) do
    with {:ok, providers, metadata} <- Auth.list_providers(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         providers: providers,
         providers_metadata: metadata
       )}
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
        <.docs_action path="/authenticate" />
      </:action>
      <:action>
        <.add_button navigate={~p"/#{@account}/settings/identity_providers/new"}>
          Add Identity Provider
        </.add_button>
      </:action>
      <:help>
        Identity providers authenticate and sync your users and groups with an external source.
      </:help>
      <:content>
        <.flash_group flash={@flash} />

        <.live_table
          id="providers"
          rows={@providers}
          row_id={&"providers-#{&1.id}"}
          filters={@filters_by_table_id["providers"]}
          filter={@filter_form_by_table_id["providers"]}
          ordered_by={@order_by_table_id["providers"]}
          metadata={@providers_metadata}
        >
          <:col :let={provider} field={{:providers, :name}} label="Name" class="w-2/12">
            <.link navigate={view_provider(@account, provider)} class={[link_style()]}>
              {provider.name}
            </.link>
          </:col>
          <:col :let={provider} label="Type" class="w-2/12">
            {adapter_name(provider.adapter)}
          </:col>
          <:col :let={provider} label="Status" class="w-2/12">
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
        </.live_table>
      </:content>
    </.section>
    """
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)
end
