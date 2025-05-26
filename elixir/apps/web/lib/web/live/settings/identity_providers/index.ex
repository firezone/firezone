defmodule Web.Settings.IdentityProviders.Index do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.{Auth, Actors}
  require Logger

  def mount(_params, _session, socket) do
    with {:ok, identities_count_by_provider_id} <-
           Auth.fetch_identities_count_grouped_by_provider_id(socket.assigns.subject),
         {:ok, groups_count_by_provider_id} <-
           Actors.fetch_groups_count_grouped_by_provider_id(socket.assigns.subject) do
      socket =
        socket
        |> assign(
          default_provider_changed: false,
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

        <div class="pb-8 px-1">
          <div class="text-lg text-neutral-600 mb-4">
            Default Authentication Provider
          </div>
          <.default_provider_form
            providers={@providers}
            default_provider_changed={@default_provider_changed}
          />
        </div>

        <div class="text-lg text-neutral-600 mb-4 px-1">
          All Identity Providers
        </div>
        <.live_table
          id="providers"
          rows={@providers}
          row_id={&"providers-#{&1.id}"}
          filters={@filters_by_table_id["providers"]}
          filter={@filter_form_by_table_id["providers"]}
          ordered_by={@order_by_table_id["providers"]}
          metadata={@providers_metadata}
        >
          <:col :let={provider} field={{:providers, :name}} label="Name" class="w-3/12">
            <div class="flex flex-wrap">
              <.link navigate={view_provider(@account, provider)} class={[link_style()]}>
                {provider.name}
              </.link>
              <.assigned_default_badge provider={provider} />
            </div>
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

  attr :providers, :list, required: true
  attr :default_provider_changed, :boolean, required: true

  defp default_provider_form(assigns) do
    options =
      assigns.providers
      |> Enum.filter(fn provider ->
        provider.adapter not in [:email, :userpass]
      end)
      |> Enum.map(fn provider ->
        {provider.name, provider.id}
      end)

    options = [{"None", :none} | options]

    value =
      assigns.providers
      |> Enum.find(%{id: :none}, fn provider ->
        !is_nil(provider.assigned_default_at)
      end)
      |> Map.get(:id)

    assigns = assign(assigns, options: options, value: value)

    ~H"""
    <.form
      id="default-provider-form"
      phx-submit="default_provider_save"
      phx-change="default_provider_change"
      for={nil}
    >
      <div class="flex gap-2 items-center">
        <.input
          id="default-provider-select"
          name="provider_id"
          type="select"
          options={@options}
          value={@value}
        />
        <.submit_button
          phx-disable-with="Saving..."
          {if @default_provider_changed, do: [], else: [disabled: true, style: "disabled"]}
          icon="hero-identification"
        >
          Make Default
        </.submit_button>
      </div>
      <p class="text-xs text-neutral-500 mt-2">
        When selected, users signing in from the Firezone client will be taken directly to this provider for authentication.
      </p>
    </.form>
    """
  end

  def handle_event("default_provider_change", _params, socket) do
    {:noreply, assign(socket, default_provider_changed: true)}
  end

  def handle_event("default_provider_save", %{"provider_id" => provider_id}, socket) do
    assign_default_provider(provider_id, socket)
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  # Clear default provider
  defp assign_default_provider("none", socket) do
    with {_count, nil} <- Auth.clear_default_provider(socket.assigns.subject),
         {:ok, providers, _metadata} <- Auth.list_providers(socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:info, "Default authentication provider cleared")
        |> assign(default_provider_changed: false, providers: providers)

      {:noreply, socket}
    else
      error ->
        Logger.warning("Failed to clear default auth provider",
          error: inspect(error)
        )

        socket =
          socket
          |> put_flash(
            :error,
            "Failed to update default auth provider. Contact support if this issue persists."
          )

        {:noreply, socket}
    end
  end

  defp assign_default_provider(provider_id, socket) do
    provider =
      socket.assigns.providers
      |> Enum.find(fn provider -> provider.id == provider_id end)

    with true <- provider.adapter not in [:email, :userpass],
         {:ok, _provider} <- Auth.assign_default_provider(provider, socket.assigns.subject),
         {:ok, providers, _metadata} <- Auth.list_providers(socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:info, "Default authentication provider set to #{provider.name}")
        |> assign(default_provider_changed: false, providers: providers)

      {:noreply, socket}
    else
      error ->
        Logger.warning("Failed to set default auth provider",
          error: inspect(error)
        )

        socket =
          socket
          |> put_flash(
            :error,
            "Failed to update default auth provider. Contact support if this issue persists."
          )

        {:noreply, socket}
    end
  end
end
