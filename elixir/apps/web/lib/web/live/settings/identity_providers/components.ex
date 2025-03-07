defmodule Web.Settings.IdentityProviders.Components do
  use Web, :component_library

  def status(%{provider: %{deleted_at: deleted_at}} = assigns) when not is_nil(deleted_at) do
    ~H"""
    <div class="flex items-center">
      <.ping_icon color="info" />
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
      <.ping_icon color="danger" />
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
      <.ping_icon color="danger" />
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
            adapter: :microsoft_entra,
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
      <.ping_icon color="danger" />
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
            adapter: :microsoft_entra,
            disabled_at: disabled_at,
            adapter_state: %{"status" => "pending_access_token"}
          }
        } = assigns
      )
      when not is_nil(disabled_at) do
    ~H"""
    <div class="flex items-center">
      <.ping_icon color="danger" />
      <span class="ml-3">
        Provisioning
        <span :if={@provider.adapter_state["status"]}>
          <.button
            size="xs"
            navigate={
              ~p"/#{@provider.account_id}/settings/identity_providers/microsoft_entra/#{@provider}/redirect"
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
            adapter: :okta,
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
      <.ping_icon color="danger" />
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
            adapter: :okta,
            disabled_at: disabled_at,
            adapter_state: %{"status" => "pending_access_token"}
          }
        } = assigns
      )
      when not is_nil(disabled_at) do
    ~H"""
    <div class="flex items-center">
      <.ping_icon color="danger" />
      <span class="ml-2.5">
        Provisioning
        <span :if={@provider.adapter_state["status"]}>
          <.button
            size="xs"
            navigate={
              ~p"/#{@provider.account_id}/settings/identity_providers/okta/#{@provider}/redirect"
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
            adapter: :jumpcloud,
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
              ~p"/#{@provider.account_id}/settings/identity_providers/jumpcloud/#{@provider}/redirect"
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
      <.ping_icon color="danger" />
      <span class="ml-2.5">
        Provisioning
        <span :if={@provider.adapter_state["status"]}>
          <.button
            size="xs"
            navigate={
              ~p"/#{@provider.account_id}/settings/identity_providers/openid_connect/#{@provider}/redirect"
            }
          >
            Connect IdP
          </.button>
        </span>
      </span>
    </div>
    """
  end

  def status(%{provider: %{disabled_at: disabled_at}} = assigns) when not is_nil(disabled_at) do
    ~H"""
    <div class="flex items-center">
      <.ping_icon color="info" />
      <span class="ml-2.5">
        Disabled
      </span>
    </div>
    """
  end

  def status(assigns) do
    ~H"""
    <div class="flex items-center">
      <.ping_icon color="success" />
      <span class="ml-2.5">
        Active
      </span>
    </div>
    """
  end

  def adapter_name(:email), do: "Email"
  def adapter_name(:userpass), do: "Username & Password"
  def adapter_name(:google_workspace), do: "Google Workspace"
  def adapter_name(:microsoft_entra), do: "Microsoft Entra"
  def adapter_name(:okta), do: "Okta"
  def adapter_name(:jumpcloud), do: "JumpCloud"
  def adapter_name(:mock), do: "Mock"
  def adapter_name(:openid_connect), do: "OpenID Connect"

  def view_provider(account, %{adapter: adapter} = provider)
      when adapter in [:email, :userpass],
      do: ~p"/#{account}/settings/identity_providers/system/#{provider}"

  def view_provider(account, %{adapter: :openid_connect} = provider),
    do: ~p"/#{account}/settings/identity_providers/openid_connect/#{provider}"

  def view_provider(account, %{adapter: :google_workspace} = provider),
    do: ~p"/#{account}/settings/identity_providers/google_workspace/#{provider}"

  def view_provider(account, %{adapter: :microsoft_entra} = provider),
    do: ~p"/#{account}/settings/identity_providers/microsoft_entra/#{provider}"

  def view_provider(account, %{adapter: :okta} = provider),
    do: ~p"/#{account}/settings/identity_providers/okta/#{provider}"

  def view_provider(account, %{adapter: :jumpcloud} = provider),
    do: ~p"/#{account}/settings/identity_providers/jumpcloud/#{provider}"

  def view_provider(account, %{adapter: :mock} = provider),
    do: ~p"/#{account}/settings/identity_providers/mock/#{provider}"

  def sync_status(%{provider: %{provisioner: :custom}} = assigns) do
    ~H"""
    <div :if={not is_nil(@provider.last_synced_at)} class="flex items-center">
      <.ping_icon color={
        (@provider.last_syncs_failed > 3 or (not is_nil(@provider.sync_disabled_at) && "danger")) ||
          "success"
      } />
      <span class="ml-2.5">
        Synced
        <.link
          navigate={~p"/#{@account}/actors?#{%{"actors_filter[provider_id]" => @provider.id}}"}
          class={link_style()}
        >
          <% identities_count_by_provider_id = @identities_count_by_provider_id[@provider.id] || 0 %>
          {identities_count_by_provider_id}
          <.cardinal_number
            number={identities_count_by_provider_id}
            one="identity"
            other="identities"
          />
        </.link>
        and
        <.link
          navigate={~p"/#{@account}/groups?#{%{"groups_filter[provider_id]" => @provider.id}}"}
          class={link_style()}
        >
          <% groups_count_by_provider_id = @groups_count_by_provider_id[@provider.id] || 0 %>
          {groups_count_by_provider_id}
          <.cardinal_number number={groups_count_by_provider_id} one="group" other="groups" />
        </.link>

        <.relative_datetime datetime={@provider.last_synced_at} />
      </span>
    </div>
    <div :if={is_nil(@provider.last_synced_at)} class="flex items-center">
      <.ping_icon color="danger" />
      <span class="ml-2.5">
        Never synced
      </span>
    </div>
    """
  end

  def sync_status(%{provider: %{provisioner: provisioner}} = assigns)
      when provisioner in [:just_in_time, :manual] do
    ~H"""
    <div class="flex items-center">
      <.ping_icon color="success" />
      <span class="ml-2.5">
        Created
        <.link
          navigate={~p"/#{@account}/actors?#{%{"actors_filter[provider_id]" => @provider.id}}"}
          class={link_style()}
        >
          <% identities_count_by_provider_id = @identities_count_by_provider_id[@provider.id] || 0 %>
          {identities_count_by_provider_id}
          <.cardinal_number
            number={identities_count_by_provider_id}
            one="identity"
            other="identities"
          />
        </.link>
        and
        <.link
          navigate={~p"/#{@account}/groups?#{%{"groups_filter[provider_id]" => @provider.id}}"}
          class={link_style()}
        >
          <% groups_count_by_provider_id = @groups_count_by_provider_id[@provider.id] || 0 %>
          {groups_count_by_provider_id}
          <.cardinal_number number={groups_count_by_provider_id} one="group" other="groups" />
        </.link>
      </span>
    </div>
    """
  end
end
