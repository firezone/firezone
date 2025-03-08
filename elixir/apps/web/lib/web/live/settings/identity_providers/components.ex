defmodule Web.Settings.IdentityProviders.Components do
  use Web, :component_library
  import Web.LiveTable
  alias Domain.Actors

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
                <.icon
                  :if={removed?(@removed, group)}
                  name="hero-minus"
                  class="h-3.5 w-3.5 mr-2 text-red-500"
                />
                <.icon
                  :if={added?(@added, group)}
                  name="hero-plus"
                  class="h-3.5 w-3.5 mr-2 text-green-500"
                />

                {group.name |> String.trim_leading("Group:")}
              </:col>
              <:col :let={group}>
                <div class="flex justify-end">
                  <.button
                    :if={show_remove_button?(@added, @removed, group)}
                    size="xs"
                    style="info"
                    icon="hero-minus"
                    phx-click="remove_group"
                    phx-value-id={group.id}
                    phx-value-name={group.name}
                    phx-value-excluded_at={group.excluded_at}
                  >
                    Remove
                  </.button>
                  <.button
                    :if={show_add_button?(@added, @removed, group)}
                    size="xs"
                    style="info"
                    icon="hero-plus"
                    phx-click="add_group"
                    phx-value-id={group.id}
                    phx-value-name={group.name}
                    phx-value-excluded_at={group.excluded_at}
                  >
                    Add
                  </.button>
                </div>
              </:col>
            </.live_table>
          </fieldset>
          <div class="flex justify-between items-center">
            <p class="px-4 text-sm text-gray-500">
              {pending_changes(@added, @removed)}
            </p>

            <.button_group>
              <:button label="Select All" event="select_all" />
              <:button label="Select None" event="select_none" />
              <:button label="Reset" event="reset_selection" />
            </.button_group>

            <.button_with_confirmation
              id="save_changes"
              {group_filters_changed?(@added, @removed) && %{} || %{disabled: "disabled"}}
              style={(group_filters_changed?(@added, @removed) && "primary") || "disabled"}
              confirm_style="primary"
              class="m-4"
              on_confirm="submit"
            >
              <:dialog_title>Confirm changes to Actor Groups</:dialog_title>
              <:dialog_content>
                {confirm_message(@added, @removed)}
              </:dialog_content>
              <:dialog_confirm_button>
                Save
              </:dialog_confirm_button>
              <:dialog_cancel_button>
                Cancel
              </:dialog_cancel_button>
              Save
            </.button_with_confirmation>
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

  defp group_filters_changed?(added, removed) do
    Enum.any?(added) or Enum.any?(removed)
  end

  defp show_add_button?(added, removed, group) do
    (is_nil(group.excluded_at) and not added?(added, group)) or
      (!is_nil(group.excluded_at) and removed?(removed, group))
  end

  defp show_remove_button?(added, removed, group) do
    (!is_nil(group.excluded_at) and not removed?(removed, group)) or added?(added, group)
  end

  defp added?(added, group) do
    Enum.any?(added, fn {id, _name} -> id == group.id end)
  end

  defp removed?(removed, group) do
    Enum.any?(removed, fn {id, _name} -> id == group.id end)
  end

  defp pending_changes(added, removed) do
    if group_filters_changed?(added, removed) do
      "#{Enum.count(added)} added, #{Enum.count(removed)} removed"
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
      Actors.all_deleted_and_excluded_groups_for!(socket.assigns.provider, socket.assigns.subject)

    added =
      Enum.reduce(all_groups, %{}, fn group, acc ->
        if group.excluded_at do
          acc
        else
          Map.put(acc, group.id, group.name)
        end
      end)

    {:noreply, assign(socket, added: added, removed: %{})}
  end

  def handle_group_filters_event("select_none", _params, socket) do
    all_groups =
      Actors.all_deleted_and_excluded_groups_for!(socket.assigns.provider, socket.assigns.subject)

    removed =
      Enum.reduce(all_groups, %{}, fn group, acc ->
        if group.excluded_at do
          Map.put(acc, group.id, group.name)
        else
          acc
        end
      end)

    {:noreply, assign(socket, added: %{}, removed: removed)}
  end

  def handle_group_filters_event("reset_selection", _params, socket) do
    {:noreply, assign(socket, added: %{}, removed: %{})}
  end

  def handle_group_filters_event("add_group", %{"id" => id, "name" => name} = params, socket) do
    removed = Map.delete(socket.assigns.removed, id)

    if params["excluded_at"] do
      {:noreply, assign(socket, removed: removed)}
    else
      added = Map.put(socket.assigns.added, id, name)
      {:noreply, assign(socket, added: added, removed: removed)}
    end
  end

  def handle_group_filters_event("remove_group", %{"id" => id, "name" => name} = params, socket) do
    added = Map.delete(socket.assigns.added, id)

    if params["excluded_at"] do
      removed = Map.put(socket.assigns.removed, id, name)
      {:noreply, assign(socket, added: added, removed: removed)}
    else
      {:noreply, assign(socket, added: added)}
    end
  end

  def handle_group_filters_event("submit", _params, socket) do
    # TODO: Set excluded_at for groups that were removed
    # TODO: Remove excluded_at for groups that were added
    # added_ids = Map.keys(socket.assigns.added)
    # removed_ids = Map.keys(socket.assigns.removed)

    {:noreply,
     assign(socket,
       added: %{},
       removed: %{}
     )}
  end

  def handle_group_filters_update!(socket, list_opts) do
    with {:ok, groups, metadata} <-
           Actors.list_all_deleted_and_excluded_groups_for(
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
