defmodule Web.Settings.IdentityProviders.Components do
  use Web, :component_library
  import Web.LiveTable
  alias Domain.{Actors, Auth}

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
    <.section>
      <:title>
        Group Filters
      </:title>
      <:help>
        Group filters allow you to control which groups are synced from the Identity Provider.
        By default, all groups are included.
      </:help>
      <:action>
        <.docs_action path="/authenticate/directory-sync" fragment="group-filters" />
      </:action>
      <:content>
        <%= if @provider.last_synced_at do %>
          <form phx-change="toggle_filters">
            <.switch
              name="group_filters_enabled"
              checked={@group_filters_enabled}
              label="Enable group filters"
              label_placement="left"
            />
          </form>
          <fieldset
            disabled={!@group_filters_enabled}
            class={if @group_filters_enabled, do: "", else: "opacity-50"}
          >
            <.live_table
              id="groups"
              rows={@groups}
              row_id={&"group-#{&1.id}"}
              filters={@filters_by_table_id["groups"]}
              filter={@filter_form_by_table_id["groups"]}
              ordered_by={@order_by_table_id["groups"]}
              metadata={@groups_metadata}
            >
              <:col :let={group} label="group">
                <span class={included_excluded_class(@included, @excluded, group)}>
                  {group.name |> String.trim_leading("Group:")}
                </span>
              </:col>
              <:col :let={group} class="text-right" label="include in sync">
                <div class="flex justify-end">
                  <.input
                    class={(@group_filters_enabled && "cursor-pointer") || "cursor-not-allowed"}
                    type="checkbox"
                    name={"group_inclusion_#{group.id}"}
                    checked={checkbox_state(@included, @excluded, group)}
                    phx-click="toggle_group_inclusion"
                    phx-value-id={group.id}
                    phx-value-name={group.name}
                    phx-value-included_at={group.included_at}
                  />
                </div>
              </:col>
            </.live_table>
          </fieldset>
          <div class="grid grid-cols-3 items-center">
            <div class="justify-self-start">
              <p class="px-4 text-sm text-gray-500">
                {summary(
                  @provider.group_filters_enabled_at,
                  @group_filters_enabled,
                  @included,
                  @excluded
                )}
              </p>
            </div>

            <div class="justify-self-center">
              <.button_group style={(@group_filters_enabled && "info") || "disabled"}>
                <:button label="Select All" event="select_all" />
                <:button label="Select None" event="select_none" />
                <:button label="Reset" event="reset_selection" />
              </.button_group>
            </div>

            <div class="justify-self-end">
              <.button_with_confirmation
                id="save_changes"
                {group_filters_changed?(@provider.group_filters_enabled_at, @group_filters_enabled, @included, @excluded) && %{} || %{disabled: "disabled"}}
                style={
                  (group_filters_changed?(
                     @provider.group_filters_enabled_at,
                     @group_filters_enabled,
                     @included,
                     @excluded
                   ) && "primary") || "disabled"
                }
                confirm_style="primary"
                class="m-4"
                on_confirm="submit"
              >
                <:dialog_title>Confirm changes to Group filters</:dialog_title>
                <:dialog_content>
                  {confirm_message(@included, @excluded)}
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
              Never synced
            </span>
          </div>
        <% end %>
      </:content>
    </.section>
    """
  end

  defp group_filters_changed?(enabled_at, enabled, inc, exc) do
    !is_nil(enabled_at) != enabled or Enum.any?(inc) or Enum.any?(exc)
  end

  defp included_excluded_class(included, excluded, group) do
    cond do
      included?(included, group) -> "font-medium"
      excluded?(excluded, group) -> "opacity-50"
      is_nil(group.included_at) -> "opacity-50"
      true -> "font-medium"
    end
  end

  def checkbox_state(included, excluded, group) do
    cond do
      included?(included, group) -> true
      excluded?(excluded, group) -> false
      is_nil(group.included_at) -> false
      true -> true
    end
  end

  defp included?(included, group) do
    Map.has_key?(included, group.id)
  end

  defp excluded?(excluded, group) do
    Map.has_key?(excluded, group.id)
  end

  defp summary(group_filters_enabled_at, group_filters_enabled, included, excluded) do
    if group_filters_changed?(group_filters_enabled_at, group_filters_enabled, included, excluded) do
      "#{Enum.count(included)} included, #{Enum.count(excluded)} excluded"
    else
      "No changes pending"
    end
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

  def handle_group_filters_event(event, params, socket)
      when event in ["paginate", "order_by", "filter"],
      do: handle_live_table_event(event, params, socket)

  def handle_group_filters_event("toggle_filters", _params, socket) do
    group_filters_enabled = not socket.assigns.group_filters_enabled
    {:noreply, assign(socket, group_filters_enabled: group_filters_enabled)}
  end

  def handle_group_filters_event("select_all", _params, socket) do
    all_groups =
      Actors.all_groups_for!(socket.assigns.provider, socket.assigns.subject)

    included =
      Enum.reduce(all_groups, %{}, fn group, acc ->
        Map.put(acc, group.id, group.name)
      end)

    {:noreply, assign(socket, included: included, excluded: %{})}
  end

  def handle_group_filters_event("select_none", _params, socket) do
    all_groups =
      Actors.all_groups_for!(socket.assigns.provider, socket.assigns.subject)

    excluded =
      Enum.reduce(all_groups, %{}, fn group, acc ->
        Map.put(acc, group.id, group.name)
      end)

    {:noreply, assign(socket, included: %{}, excluded: excluded)}
  end

  def handle_group_filters_event("reset_selection", _params, socket) do
    # Reset the selection to the DB state
    socket =
      socket
      |> assign(included: %{}, excluded: %{})
      |> reload_live_table!("groups")

    {:noreply, socket}
  end

  # Checked; include in sync
  def handle_group_filters_event(
        "toggle_group_inclusion",
        %{"id" => id, "name" => name, "value" => "true"} = params,
        socket
      ) do
    if params["included_at"] do
      # included in DB; remove pending inclusion
      excluded = Map.delete(socket.assigns.excluded, id)
      {:noreply, assign(socket, excluded: excluded)}
    else
      # excluded in DB; mark as pending inclusion
      included = Map.put(socket.assigns.included, id, name)
      {:noreply, assign(socket, included: included)}
    end
  end

  # Unchecked; exclude from sync
  def handle_group_filters_event(
        "toggle_group_inclusion",
        %{"id" => id, "name" => name} = params,
        socket
      ) do
    if params["included_at"] do
      # included in DB; mark as pending inclusion
      excluded = Map.put(socket.assigns.excluded, id, name)
      {:noreply, assign(socket, excluded: excluded)}
    else
      # excluded in DB; remove pending inclusion
      included = Map.delete(socket.assigns.included, id)
      {:noreply, assign(socket, included: included)}
    end
  end

  def handle_group_filters_event("submit", _params, socket) do
    socket =
      socket
      |> submit_group_filters()
      |> assign(included: %{}, excluded: %{})
      |> reload_live_table!("groups")

    {:noreply, socket}
  end

  defp submit_group_filters(socket) do
    enabled = socket.assigns.group_filters_enabled
    provider = socket.assigns.provider
    subject = socket.assigns.subject
    included_ids = Map.keys(socket.assigns.included)
    excluded_ids = Map.keys(socket.assigns.excluded)

    {:ok, provider} =
      if enabled do
        :ok = Actors.update_group_filters_for(provider, included_ids, excluded_ids, subject)
        Auth.enable_group_filters_for(provider, subject)
      else
        Auth.disable_group_filters_for(provider, subject)
      end

    assign(socket, provider: provider)
  end

  def handle_group_filters_update!(socket, list_opts) do
    with {:ok, groups, metadata} <-
           Actors.list_all_groups_for(
             socket.assigns.provider,
             socket.assigns.subject,
             list_opts
           ) do
      {:ok,
       assign(socket,
         groups: groups,
         groups_metadata: metadata
       )}
    end
  end
end
