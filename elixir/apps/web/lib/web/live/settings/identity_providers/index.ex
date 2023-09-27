defmodule Web.Settings.IdentityProviders.Index do
  use Web, :live_view
  import Web.Settings.IdentityProviders.Components
  alias Domain.{Auth, Actors}

  def mount(_params, _session, socket) do
    account = socket.assigns.account
    subject = socket.assigns.subject

    with {:ok, providers} <- Auth.list_providers_for_account(account, subject),
         {:ok, identities_count_by_provider_id} <-
           Auth.fetch_identities_count_grouped_by_provider_id(subject),
         {:ok, groups_count_by_provider_id} <-
           Actors.fetch_groups_count_grouped_by_provider_id(subject) do
      {:ok, socket,
       temporary_assigns: [
         identities_count_by_provider_id: identities_count_by_provider_id,
         groups_count_by_provider_id: groups_count_by_provider_id,
         providers: providers,
         page_title: "Identity Providers Settings"
       ]}
    else
      _ -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/actors"}>
      <.breadcrumb path={~p"/#{@account}/settings/identity_providers"}>
        Identity Providers Settings
      </.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        Identity Providers
      </:title>

      <:actions>
        <.add_button navigate={~p"/#{@account}/settings/identity_providers/new"}>
          Add Identity Provider
        </.add_button>
      </:actions>
    </.header>
    <p class="ml-4 mb-4 font-medium bg-gray-50 dark:bg-gray-800 text-gray-600 dark:text-gray-500">
      <.link
        class="text-blue-600 dark:text-blue-500 hover:underline"
        href="https://www.firezone.dev/docs/architecture/sso"
        target="_blank"
      >
        Read more about how SSO works in Firezone.
        <.icon name="hero-arrow-top-right-on-square" class="-ml-1 mb-3 w-3 h-3" />
      </.link>
    </p>

    <.flash_group flash={@flash} />

    <div class="bg-white dark:bg-gray-800 overflow-hidden">
      <.table id="providers" rows={@providers} row_id={&"providers-#{&1.id}"}>
        <:col :let={provider} label="Name">
          <.link
            navigate={view_provider(@account, provider)}
            class="font-medium text-blue-600 dark:text-blue-500 hover:underline"
          >
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
      </.table>
    </div>
    """
  end

  def sync_status(%{provider: %{provisioner: :custom}} = assigns) do
    ~H"""
    <div :if={not is_nil(@provider.last_synced_at)} class="flex items-center">
      <span class="w-3 h-3 bg-green-500 rounded-full"></span>
      <span class="ml-3">
        Synced
        <.link
          navigate={~p"/#{@account}/actors?provider_id=#{@provider.id}"}
          class="text-blue-600 dark:text-blue-500 hover:underline"
        >
          <% identities_count_by_provider_id = @identities_count_by_provider_id[@provider.id] || 0 %>
          <%= identities_count_by_provider_id %>
          <.cardinal_number
            number={identities_count_by_provider_id}
            one="identity"
            other="identities"
          />
        </.link>
        and
        <.link
          navigate={~p"/#{@account}/groups?provider_id=#{@provider.id}"}
          class="text-blue-600 dark:text-blue-500 hover:underline"
        >
          <% groups_count_by_provider_id = @groups_count_by_provider_id[@provider.id] || 0 %>
          <%= groups_count_by_provider_id %>
          <.cardinal_number number={groups_count_by_provider_id} one="group" other="groups" />
        </.link>

        <.relative_datetime datetime={@provider.last_synced_at} />
      </span>
    </div>
    <div :if={is_nil(@provider.last_synced_at)} class="flex items-center">
      <span class="w-3 h-3 bg-red-500 rounded-full"></span>
      <span class="ml-3">
        Never synced
      </span>
    </div>
    """
  end

  def sync_status(%{provider: %{provisioner: provisioner}} = assigns)
      when provisioner in [:just_in_time, :manual] do
    ~H"""
    <div class="flex items-center">
      <span class="w-3 h-3 bg-green-500 rounded-full"></span>
      <span class="ml-3">
        Created
        <.link
          navigate={~p"/#{@account}/actors?provider_id=#{@provider.id}"}
          class="text-blue-600 dark:text-blue-500 hover:underline"
        >
          <% identities_count_by_provider_id = @identities_count_by_provider_id[@provider.id] || 0 %>
          <%= identities_count_by_provider_id %>
          <.cardinal_number
            number={identities_count_by_provider_id}
            one="identity"
            other="identities"
          />
        </.link>
        and
        <.link
          navigate={~p"/#{@account}/groups?provider_id=#{@provider.id}"}
          class="text-blue-600 dark:text-blue-500 hover:underline"
        >
          <% groups_count_by_provider_id = @groups_count_by_provider_id[@provider.id] || 0 %>
          <%= groups_count_by_provider_id %>
          <.cardinal_number number={groups_count_by_provider_id} one="group" other="groups" />
        </.link>
      </span>
    </div>
    """
  end
end
