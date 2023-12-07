defmodule Web.Settings.IdentityProviders.Components do
  use Web, :component_library

  def status(%{provider: %{deleted_at: deleted_at}} = assigns) when not is_nil(deleted_at) do
    ~H"""
    <div class="flex items-center">
      <span class="w-3 h-3 bg-neutral-500 rounded-full"></span>
      <span class="ml-3">
        Deleted
      </span>
    </div>
    """
  end

  def status(
        %{
          provider: %{
            adapter: :google_workspace,
            adapter_state: %{"refresh_token" => nil, "expires_at" => expires_at},
            disabled_at: nil
          }
        } = assigns
      ) do
    assigns =
      assign_new(assigns, :expires_at, fn ->
        {:ok, dt, _} = DateTime.from_iso8601(expires_at)
        dt
      end)

    ~H"""
    <div class="flex items-center">
      <span class="w-3 h-3 bg-red-500 rounded-full"></span>
      <span class="ml-3">
        No refresh token provided by IdP and access token expires on
        <.datetime datetime={@expires_at} /> UTC
      </span>
    </div>
    """
  end

  def status(
        %{
          provider: %{
            adapter: :google_workspace,
            disabled_at: disabled_at,
            adapter_state: %{"status" => "pending_access_token"}
          }
        } = assigns
      )
      when not is_nil(disabled_at) do
    ~H"""
    <div class="flex items-center">
      <span class="w-3 h-3 bg-red-500 rounded-full"></span>
      <span class="ml-3">
        Provisioning
        <span :if={@provider.adapter_state["status"]}>
          <.button
            size="xs"
            navigate={
              ~p"/#{@provider.account_id}/settings/identity_providers/google_workspace/#{@provider}/redirect"
            }
          >
            Connect IdP
          </.button>
        </span>
      </span>
    </div>
    """
  end

  def status(
        %{
          provider: %{
            adapter: :openid_connect,
            disabled_at: disabled_at,
            adapter_state: %{"status" => "pending_access_token"}
          }
        } = assigns
      )
      when not is_nil(disabled_at) do
    ~H"""
    <div class="flex items-center">
      <span class="w-3 h-3 bg-red-500 rounded-full"></span>
      <span class="ml-3">
        Provisioning
        <span :if={@provider.adapter_state["status"]}>
          <.link navigate={
            ~p"/#{@provider.account_id}/settings/identity_providers/openid_connect/#{@provider}/redirect"
          }>
            <button class={~w[
          text-white bg-primary-600 rounded
          font-medium text-sm
          px-2 py-1 text-center
          hover:bg-primary-700
          focus:ring-4 focus:outline-none focus:ring-primary-300
          dark:bg-primary-600 dark:hover:bg-primary-700 dark:focus:ring-primary-800
          active:text-white/80
        ]}>connect IdP</button>
          </.link>
        </span>
      </span>
    </div>
    """
  end

  def status(%{provider: %{disabled_at: disabled_at}} = assigns) when not is_nil(disabled_at) do
    ~H"""
    <div class="flex items-center">
      <span class="w-3 h-3 bg-neutral-500 rounded-full"></span>
      <span class="ml-3">
        Disabled
      </span>
    </div>
    """
  end

  def status(assigns) do
    ~H"""
    <div class="flex items-center">
      <span class="w-3 h-3 bg-green-500 rounded-full"></span>
      <span class="ml-3">
        Active
      </span>
    </div>
    """
  end

  def adapter_name(:email), do: "Email"
  def adapter_name(:userpass), do: "Username & Password"
  def adapter_name(:token), do: "API Access Token"
  def adapter_name(:workos), do: "WorkOS"
  def adapter_name(:google_workspace), do: "Google Workspace"
  def adapter_name(:openid_connect), do: "OpenID Connect"
  def adapter_name(:saml), do: "SAML 2.0"

  def view_provider(account, %{adapter: adapter} = provider)
      when adapter in [:email, :userpass, :token],
      do: ~p"/#{account}/settings/identity_providers/system/#{provider}"

  def view_provider(account, %{adapter: :openid_connect} = provider),
    do: ~p"/#{account}/settings/identity_providers/openid_connect/#{provider}"

  def view_provider(account, %{adapter: :google_workspace} = provider),
    do: ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}"

  def view_provider(account, %{adapter: :saml} = provider),
    do: ~p"/#{account}/settings/identity_providers/saml/#{provider}"

  def sync_status(%{provider: %{provisioner: :custom}} = assigns) do
    ~H"""
    <div :if={not is_nil(@provider.last_synced_at)} class="flex items-center">
      <span class="w-3 h-3 bg-green-500 rounded-full"></span>
      <span class="ml-3">
        Synced
        <.link navigate={~p"/#{@account}/actors?provider_id=#{@provider.id}"} class={link_style()}>
          <% identities_count_by_provider_id = @identities_count_by_provider_id[@provider.id] || 0 %>
          <%= identities_count_by_provider_id %>
          <.cardinal_number
            number={identities_count_by_provider_id}
            one="identity"
            other="identities"
          />
        </.link>
        and
        <.link navigate={~p"/#{@account}/groups?provider_id=#{@provider.id}"} class={link_style()}>
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
        <.link navigate={~p"/#{@account}/actors?provider_id=#{@provider.id}"} class={link_style()}>
          <% identities_count_by_provider_id = @identities_count_by_provider_id[@provider.id] || 0 %>
          <%= identities_count_by_provider_id %>
          <.cardinal_number
            number={identities_count_by_provider_id}
            one="identity"
            other="identities"
          />
        </.link>
        and
        <.link navigate={~p"/#{@account}/groups?provider_id=#{@provider.id}"} class={link_style()}>
          <% groups_count_by_provider_id = @groups_count_by_provider_id[@provider.id] || 0 %>
          <%= groups_count_by_provider_id %>
          <.cardinal_number number={groups_count_by_provider_id} one="group" other="groups" />
        </.link>
      </span>
    </div>
    """
  end
end
