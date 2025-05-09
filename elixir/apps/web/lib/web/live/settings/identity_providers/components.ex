defmodule Web.Settings.IdentityProviders.Components do
  use Web, :component_library
  alias Domain.Auth

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

  def group_filters(assigns) do
    ~H"""
    <%= if @fetched_groups do %>
      <form phx-change="toggle_filters">
        <.switch
          name="enabled"
          checked={@enabled}
          label="Enable group filters"
          label_placement="left"
        />
      </form>
      <fieldset disabled={!@enabled} class={if @enabled, do: "", else: "opacity-50"}>
        <ul id="groups">
          <%= for {provider_identifier, group_name} <- @fetched_groups do %>
            <li>{group_name}</li>
          <% end %>
        </ul>
      </fieldset>
      <div class="grid grid-cols-3 items-center">
        <div class="justify-self-start">
          <p class="px-4 text-sm text-gray-500">
            {summary(
              @provider.group_filters_enabled_at,
              @enabled,
              @to_include,
              @to_exclude
            )}
          </p>
        </div>

        <div class="justify-self-center">
          <.button_group style={(@enabled && "info") || "disabled"}>
            <:button label="Select All" event="select_all" />
            <:button label="Select None" event="select_none" />
            <:button label="Reset" event="reset_selection" />
          </.button_group>
        </div>

        <div class="justify-self-end">
          <.button_with_confirmation
            id="save_changes"
            {group_filters_changed?(@provider.group_filters_enabled_at, @enabled, @to_include, @to_exclude) && %{} || %{disabled: "disabled"}}
            style={
              (group_filters_changed?(
                 @provider.group_filters_enabled_at,
                 @enabled,
                 @to_include,
                 @to_exclude
               ) && "primary") || "disabled"
            }
            confirm_style="primary"
            class="m-4"
            on_confirm="submit"
          >
            <:dialog_title>Confirm changes to Group filters</:dialog_title>
            <:dialog_content>
              {confirm_message(@to_include, @to_exclude)}
            </:dialog_content>
            <:dialog_confirm_button>
              Save
            </:dialog_confirm_button>
            <:dialog_cancel_button>
              Cancel
            </:dialog_cancel_button>
            Save Selections…
          </.button_with_confirmation>
        </div>
      </div>
    <% else %>
      <div class="flex items-center justify-center w-full h-12 bg-red-500 text-white">
        <span>
          Fetching groups from the identity provider...
        </span>
      </div>
    <% end %>
    """
  end

  defp summary(enabled_at, enabled, to_include, to_exclude) do
    if group_filters_changed?(enabled_at, enabled, to_include, to_exclude) do
      "#{map_size(to_include)} included, #{map_size(to_exclude)} excluded"
    else
      "No changes pending"
    end
  end

  defp group_filters_changed?(enabled_at, enabled, to_include, to_exclude) do
    !is_nil(enabled_at) != enabled or Enum.any?(to_include) or Enum.any?(to_exclude)
  end

  defp confirm_message(added, removed) do
    added_names = Enum.map(added, fn {_id, name} -> name end)
    removed_names = Enum.map(removed, fn {_id, name} -> name end)

    add = if added_names != [], do: "add #{Enum.join(added_names, ", ")}"
    remove = if removed_names != [], do: "remove #{Enum.join(removed_names, ", ")}"
    change = [add, remove] |> Enum.reject(&is_nil/1) |> Enum.join(" and ")

    if change == "" do
      # Don't show confirmation message if no changes were made
      nil
    else
      "Are you sure you want to #{change}?"
    end
  end

  # Shared event handlers for group filters

  def handle_group_filters_event("toggle_filters", _params, socket) do
    enabled = not socket.assigns.enabled

    {:noreply, assign(socket, enabled: enabled)}
  end

  def handle_group_filters_event("select_all", _params, socket) do
    to_include =
      socket.assigns.fetched_groups
      |> Enum.into(%{})

    to_exclude = %{}

    {:noreply, assign(socket, to_include: to_include, to_exclude: to_exclude)}
  end

  def handle_group_filters_event("select_none", _params, socket) do
    to_include = %{}

    to_exclude =
      socket.assigns.fetched_groups
      |> Enum.into(%{})

    {:noreply, assign(socket, to_include: to_include, to_exclude: to_exclude)}
  end

  def handle_group_filters_event("reset_selection", _params, socket) do
    to_include = %{}
    to_exclude = %{}

    {:noreply, assign(socket, to_include: to_include, to_exclude: to_exclude)}
  end

  # Checked; include in sync
  def handle_group_filters_event(
        "toggle_group_inclusion",
        %{"provider_identifier" => provider_identifier, "name" => name, "value" => "true"},
        socket
      ) do
    if MapSet.member?(socket.assigns.currently_included, provider_identifier) do
      # included in DB; remove pending inclusion
      {:noreply,
       assign(socket, to_exclude: Map.delete(socket.assigns.to_exclude, provider_identifier))}
    else
      # excluded in DB; mark as pending inclusion
      {:noreply,
       assign(socket, to_include: Map.put(socket.assigns.to_include, provider_identifier, name))}
    end
  end

  # Unchecked; exclude from sync
  def handle_group_filters_event(
        "toggle_group_inclusion",
        %{"provider_identifier" => provider_identifier, "name" => name},
        socket
      ) do
    if MapSet.member?(socket.assigns.currently_included, provider_identifier) do
      # included in DB; mark as pending inclusion
      {:noreply,
       assign(socket, to_exclude: Map.put(socket.assigns.to_exclude, provider_identifier, name))}
    else
      # excluded in DB; remove pending inclusion
      {:noreply,
       assign(socket, to_include: Map.delete(socket.assigns.to_include, provider_identifier))}
    end
  end

  def handle_group_filters_event("submit", _params, socket) do
    provider = socket.assigns.provider
    subject = socket.assigns.subject
    enabled_at = if socket.assigns.enabled, do: DateTime.utc_now(), else: nil

    included_groups =
      socket.assigns.currently_included
      |> MapSet.union(MapSet.new(Map.keys(socket.assigns.to_include)))
      |> MapSet.difference(MapSet.new(Map.keys(socket.assigns.to_exclude)))

    attrs = %{group_filters_enabled_at: enabled_at, included_groups: included_groups}

    case Auth.update_provider(provider, attrs, subject) do
      {:ok, provider} ->
        {:noreply,
         assign(socket,
           provider: provider,
           currently_included: MapSet.new(provider.included_groups),
           to_include: %{},
           to_exclude: %{}
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, errors: changeset.errors)}
    end
  end
end
