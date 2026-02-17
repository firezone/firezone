defmodule PortalWeb.Policies do
  use PortalWeb, :live_view

  import PortalWeb.Policies.Components,
    only: [
      condition_type_label: 1,
      grant_condition_card: 1,
      available_conditions: 1,
      map_condition_params: 2,
      maybe_drop_unsupported_conditions: 2
    ]

  alias Portal.{Changes.Change, Policy, Authentication, PubSub}
  alias __MODULE__.Database
  import Ecto.Changeset
  import Portal.Changeset

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = PubSub.Changes.subscribe(socket.assigns.account.id)
    end

    socket =
      socket
      |> assign(stale: false)
      |> assign(page_title: "Policies")
      |> assign(selected_policy: nil, policy_providers: [])
      |> assign(confirm_disable_policy: false, confirm_delete_policy: false)
      |> assign(panel_view: :list, panel_form: nil, panel_selected_resource: nil)
      |> assign(
        panel_timezone: Map.get(socket.private[:connect_params] || %{}, "timezone", "UTC")
      )
      |> assign(
        panel_active_conditions: [],
        panel_conditions_dropdown_open: false,
        panel_location_search: "",
        panel_location_operator: "is_in",
        panel_location_values: [],
        panel_ip_range_operator: "is_in_cidr",
        panel_ip_range_values: [],
        panel_ip_range_input: "",
        panel_auth_provider_operator: "is_in",
        panel_auth_provider_values: [],
        panel_tod_values: %{}
      )
      |> assign_live_table("policies",
        query_module: Database,
        sortable_fields: [],
        hide_filters: [
          :group_id,
          :group_name,
          :resource_id,
          :resource_name,
          :site_id
        ],
        callback: &handle_policies_update!/2
      )

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    policy = Database.get_policy(id, socket.assigns.subject)
    providers = Database.all_active_providers(socket.assigns.account, socket.assigns.subject)

    filter_site =
      with %{"policies_filter" => %{"site_id" => site_id}} <- params do
        Database.get_site(site_id, socket.assigns.subject)
      else
        _ -> nil
      end

    filter_resource =
      with %{"policies_filter" => %{"resource_id" => resource_id}} <- params do
        Database.get_resource(resource_id, socket.assigns.subject)
      else
        _ -> nil
      end

    {:noreply,
     assign(
       socket,
       [
         filter_site: filter_site,
         filter_resource: filter_resource,
         selected_policy: policy,
         policy_providers: providers,
         panel_view: :list,
         panel_form: nil,
         panel_selected_resource: nil,
         confirm_disable_policy: false,
         confirm_delete_policy: false,
         return_to: uri_path(uri)
       ] ++ condition_reset()
     )}
  end

  def handle_params(params, uri, %{assigns: %{live_action: :new}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    form = new_policy(%{}, socket.assigns.subject) |> to_form()
    providers = Database.all_active_providers(socket.assigns.account, socket.assigns.subject)

    {:noreply,
     assign(
       socket,
       [
         filter_site: nil,
         filter_resource: nil,
         selected_policy: nil,
         policy_providers: providers,
         panel_view: :new_form,
         panel_form: form,
         panel_selected_resource: nil,
         confirm_disable_policy: false,
         confirm_delete_policy: false,
         return_to: uri_path(uri)
       ] ++ condition_reset()
     )}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    policy = Database.get_policy(id, socket.assigns.subject)
    form = change_policy(policy) |> to_form()

    filter_site =
      with %{"policies_filter" => %{"site_id" => site_id}} <- params do
        Database.get_site(site_id, socket.assigns.subject)
      else
        _ -> nil
      end

    filter_resource =
      with %{"policies_filter" => %{"resource_id" => resource_id}} <- params do
        Database.get_resource(resource_id, socket.assigns.subject)
      else
        _ -> nil
      end

    {:noreply,
     assign(
       socket,
       [
         filter_site: filter_site,
         filter_resource: filter_resource,
         selected_policy: policy,
         policy_providers:
           Database.all_active_providers(socket.assigns.account, socket.assigns.subject),
         panel_view: :edit_form,
         panel_form: form,
         panel_selected_resource: policy.resource,
         confirm_disable_policy: false,
         confirm_delete_policy: false,
         return_to: uri_path(uri)
       ] ++ init_condition_assigns(policy)
     )}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    filter_site =
      with %{"policies_filter" => %{"site_id" => site_id}} <- params do
        Database.get_site(site_id, socket.assigns.subject)
      else
        _ -> nil
      end

    filter_resource =
      with %{"policies_filter" => %{"resource_id" => resource_id}} <- params do
        Database.get_resource(resource_id, socket.assigns.subject)
      else
        _ -> nil
      end

    {:noreply,
     assign(
       socket,
       [
         filter_site: filter_site,
         filter_resource: filter_resource,
         selected_policy: nil,
         policy_providers: [],
         panel_view: :list,
         panel_form: nil,
         panel_selected_resource: nil,
         confirm_disable_policy: false,
         confirm_delete_policy: false,
         return_to: uri_path(uri)
       ] ++ condition_reset()
     )}
  end

  defp uri_path(uri) do
    parsed = URI.parse(uri)

    case parsed.query do
      nil -> parsed.path
      query -> "#{parsed.path}?#{query}"
    end
  end

  def handle_policies_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, group: [:directory], resource: [])

    with {:ok, policies, metadata} <- Database.list_policies(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         policies: policies,
         policies_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.page_header>
        <:icon>
          <.icon name="remix-shield-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Policies</:title>
        <:description>
          Rules that grant a group access to a resource.
        </:description>
        <:action>
          <.docs_action path="/deploy/policies" />
          <.button style="primary" icon="remix-add-line" phx-click="open_new_policy_form">
            New Policy
          </.button>
        </:action>
        <:filters>
          <% conditions_count = Enum.count(@policies, fn p -> length(p.conditions) > 0 end) %>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border-emphasis)] bg-[var(--surface-raised)] text-[var(--text-primary)] font-medium">
            All {@policies_metadata.count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            With conditions {conditions_count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            No conditions {length(@policies) - conditions_count}
          </span>
        </:filters>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          stale={@stale}
          id="policies"
          rows={@policies}
          row_id={&"policies-#{&1.id}"}
          row_click={fn policy -> ~p"/#{@account}/policies/#{policy.id}?#{@query_params}" end}
          row_selected={
            fn policy ->
              not is_nil(@selected_policy) and policy.id == @selected_policy.id
            end
          }
          filters={@filters_by_table_id["policies"]}
          filter={@filter_form_by_table_id["policies"]}
          ordered_by={@order_by_table_id["policies"]}
          metadata={@policies_metadata}
          class="flex-1 min-h-0"
        >
          <:notice :if={@filter_site} type="info">
            Viewing Policies for Site <strong>{@filter_site.name}</strong>.
            <.link navigate={~p"/#{@account}/policies"} class={link_style()}>
              View all policies
            </.link>
          </:notice>
          <:notice :if={@filter_resource} type="info">
            Viewing Policies for Resource <strong>{@filter_resource.name}</strong>.
            <.link navigate={~p"/#{@account}/policies"} class={link_style()}>
              View all policies
            </.link>
          </:notice>
          <:col :let={policy} label="Policy">
            <div class="font-medium transition-colors text-[var(--text-primary)] group-hover:text-[var(--brand)]">
              <%= if policy.group do %>
                {policy.group.name} — {policy.resource.name}
              <% else %>
                <span class="text-amber-600">(Group deleted)</span> — {policy.resource.name}
              <% end %>
            </div>
            <div class="font-mono text-[10px] text-[var(--text-tertiary)] mt-0.5">
              {policy.id}
            </div>
          </:col>
          <:col :let={policy} label="Status" class="w-32">
            <.status_badge status={if is_nil(policy.disabled_at), do: :active, else: :disabled} />
          </:col>
          <:col :let={policy} label="Group" class="w-36 lg:w-72">
            <%= if policy.group do %>
              <div class="flex items-center gap-2">
                <div class="flex items-center justify-center w-5 h-5 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
                  <.provider_icon type={provider_type_from_group(policy.group)} class="w-3 h-3" />
                </div>
                <.link
                  navigate={~p"/#{@account}/groups/#{policy.group}"}
                  class="text-sm text-[var(--text-secondary)] truncate hover:text-[var(--text-primary)] transition-colors"
                >
                  {policy.group.name}
                </.link>
              </div>
            <% else %>
              <span class="text-xs text-[var(--text-muted)] italic">Group deleted</span>
            <% end %>
          </:col>
          <:col :let={policy} label="Resource" class="w-36 lg:w-72">
            <div class="flex items-center gap-2">
              <span class={resource_type_badge_class(policy.resource.type)}>
                {policy.resource.type}
              </span>
              <.link
                navigate={~p"/#{@account}/resources/#{policy.resource_id}"}
                class="text-sm text-[var(--text-secondary)] truncate hover:text-[var(--text-primary)] transition-colors"
              >
                {policy.resource.name}
              </.link>
            </div>
          </:col>
          <:col :let={policy} label="Conditions" class="w-28 lg:w-72">
            <%= if length(policy.conditions) > 0 do %>
              <span class="lg:hidden text-xs text-[var(--text-secondary)]">
                {length(policy.conditions)} condition{if length(policy.conditions) != 1, do: "s"}
              </span>
              <div class="hidden lg:flex items-center gap-1.5 flex-wrap">
                <%= for condition <- policy.conditions do %>
                  <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium bg-[var(--surface-raised)] text-[var(--text-secondary)] border border-[var(--border)]">
                    {condition_short_label(condition.property)}
                  </span>
                <% end %>
              </div>
            <% else %>
              <span class="text-xs text-[var(--text-muted)]">—</span>
            <% end %>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <svg
                  class="w-4 h-4 text-[var(--text-tertiary)]"
                  viewBox="0 0 16 16"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                  stroke-linejoin="round"
                >
                  <path d="M8 2L3 4v4c0 2.5 2 4.5 5 5.5 3-1 5-3 5-5.5V4L8 2z" />
                </svg>
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No policies yet</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  Create a policy to grant actors access to resources.
                </p>
              </div>
              <.link
                patch={~p"/#{@account}/policies/new"}
                class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                <.icon name="remix-add-line" class="w-3 h-3" /> Add a Policy
              </.link>
            </div>
          </:empty>
        </.live_table>
      </div>

      <.policy_panel
        account={@account}
        policy={@selected_policy}
        providers={@policy_providers}
        subject={@subject}
        panel_view={@panel_view}
        panel_form={@panel_form}
        panel_selected_resource={@panel_selected_resource}
        panel_timezone={@panel_timezone}
        panel_active_conditions={@panel_active_conditions}
        panel_conditions_dropdown_open={@panel_conditions_dropdown_open}
        panel_location_search={@panel_location_search}
        panel_location_operator={@panel_location_operator}
        panel_location_values={@panel_location_values}
        panel_ip_range_operator={@panel_ip_range_operator}
        panel_ip_range_values={@panel_ip_range_values}
        panel_ip_range_input={@panel_ip_range_input}
        panel_auth_provider_operator={@panel_auth_provider_operator}
        panel_auth_provider_values={@panel_auth_provider_values}
        panel_tod_values={@panel_tod_values}
        confirm_disable_policy={@confirm_disable_policy}
        confirm_delete_policy={@confirm_delete_policy}
      />
    </div>
    """
  end

  defp condition_reset do
    [
      panel_active_conditions: [],
      panel_conditions_dropdown_open: false,
      panel_location_search: "",
      panel_location_operator: "is_in",
      panel_location_values: [],
      panel_ip_range_operator: "is_in_cidr",
      panel_ip_range_values: [],
      panel_ip_range_input: "",
      panel_auth_provider_operator: "is_in",
      panel_auth_provider_values: [],
      panel_tod_values: %{}
    ]
  end

  def handle_event(event, params, socket)
      when event in [
             "paginate",
             "order_by",
             "filter",
             "reload",
             "table_row_click",
             "change_limit"
           ],
      do: handle_live_table_event(event, params, socket)

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/policies")}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.panel_view in [:new_form, :edit_form] do
    path =
      case socket.assigns.live_action do
        :edit -> ~p"/#{socket.assigns.account}/policies/#{socket.assigns.selected_policy.id}"
        _ -> ~p"/#{socket.assigns.account}/policies"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when not is_nil(socket.assigns.selected_policy) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/policies")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_disable_policy", _params, socket) do
    {:noreply, assign(socket, confirm_disable_policy: true)}
  end

  def handle_event("cancel_disable_policy", _params, socket) do
    {:noreply, assign(socket, confirm_disable_policy: false)}
  end

  def handle_event("confirm_delete_policy", _params, socket) do
    {:noreply, assign(socket, confirm_delete_policy: true)}
  end

  def handle_event("cancel_delete_policy", _params, socket) do
    {:noreply, assign(socket, confirm_delete_policy: false)}
  end

  def handle_event("disable_policy", _params, socket) do
    policy = socket.assigns.selected_policy
    {:ok, updated} = disable_policy(policy, socket.assigns.subject)
    updated = %{updated | group: policy.group, resource: policy.resource}

    {:noreply,
     socket
     |> put_flash(:success, "Policy disabled successfully.")
     |> assign(selected_policy: updated, confirm_disable_policy: false)
     |> reload_live_table!("policies")}
  end

  def handle_event("enable_policy", _params, socket) do
    policy = socket.assigns.selected_policy
    {:ok, updated} = enable_policy(policy, socket.assigns.subject)
    updated = %{updated | group: policy.group, resource: policy.resource}

    {:noreply,
     socket
     |> put_flash(:success, "Policy enabled successfully.")
     |> assign(selected_policy: updated)
     |> reload_live_table!("policies")}
  end

  def handle_event("delete_policy", _params, socket) do
    policy = socket.assigns.selected_policy
    {:ok, _} = delete_policy(policy, socket.assigns.subject)

    {:noreply,
     socket
     |> put_flash(:success, "Policy deleted successfully.")
     |> assign(confirm_delete_policy: false)
     |> reload_live_table!("policies")
     |> push_patch(to: ~p"/#{socket.assigns.account}/policies")}
  end

  def handle_event("open_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/policies/#{socket.assigns.selected_policy.id}/edit"
     )}
  end

  def handle_event("cancel_policy_form", _params, socket) do
    path =
      case socket.assigns.live_action do
        :edit -> ~p"/#{socket.assigns.account}/policies/#{socket.assigns.selected_policy.id}"
        _ -> ~p"/#{socket.assigns.account}/policies"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("open_new_policy_form", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/policies/new")}
  end

  def handle_event("change_policy_form", %{"policy" => params}, socket) do
    params =
      params
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    changeset =
      if socket.assigns.live_action == :new do
        new_policy(params, socket.assigns.subject)
      else
        change_policy(socket.assigns.selected_policy, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, panel_form: to_form(changeset))}
  end

  def handle_event("submit_policy_form", %{"policy" => params}, socket) do
    params =
      params
      |> map_condition_params(empty_values: :drop)
      |> maybe_drop_unsupported_conditions(socket)

    if socket.assigns.live_action == :new do
      case create_policy(params, socket.assigns.subject) do
        {:ok, policy} ->
          {:noreply,
           socket
           |> put_flash(:success, "Policy created successfully.")
           |> reload_live_table!("policies")
           |> push_patch(to: ~p"/#{socket.assigns.account}/policies/#{policy.id}")}

        {:error, changeset} ->
          {:noreply, assign(socket, panel_form: to_form(changeset))}
      end
    else
      policy = socket.assigns.selected_policy
      changeset = change_policy(policy, params)

      case Database.update_policy(changeset, socket.assigns.subject) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> put_flash(:success, "Policy updated successfully.")
           |> reload_live_table!("policies")
           |> push_patch(to: ~p"/#{socket.assigns.account}/policies/#{updated.id}")}

        {:error, changeset} ->
          {:noreply, assign(socket, panel_form: to_form(changeset))}
      end
    end
  end

  def handle_event("toggle_conditions_dropdown", _params, socket) do
    {:noreply,
     assign(socket,
       panel_conditions_dropdown_open: not socket.assigns.panel_conditions_dropdown_open
     )}
  end

  def handle_event("add_condition", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)

    {:noreply,
     assign(socket,
       panel_active_conditions: socket.assigns.panel_active_conditions ++ [type],
       panel_conditions_dropdown_open: false
     )}
  end

  def handle_event("remove_condition", %{"type" => type}, socket) do
    type = String.to_existing_atom(type)

    {:noreply,
     assign(socket,
       panel_active_conditions: List.delete(socket.assigns.panel_active_conditions, type)
     )}
  end

  def handle_event("update_location_search", %{"_location_search" => search}, socket) do
    {:noreply, assign(socket, panel_location_search: search)}
  end

  def handle_event("change_location_operator", %{"operator" => op}, socket) do
    {:noreply, assign(socket, panel_location_operator: op)}
  end

  def handle_event("toggle_location_value", %{"code" => code}, socket) do
    values = socket.assigns.panel_location_values

    updated = if code in values, do: List.delete(values, code), else: values ++ [code]

    {:noreply, assign(socket, panel_location_values: updated)}
  end

  def handle_event("change_ip_range_operator", %{"operator" => op}, socket) do
    {:noreply, assign(socket, panel_ip_range_operator: op)}
  end

  def handle_event("update_ip_range_input", %{"_ip_range_input" => value}, socket) do
    {:noreply, assign(socket, panel_ip_range_input: value)}
  end

  def handle_event("add_ip_range_value", _params, socket) do
    value = String.trim(socket.assigns.panel_ip_range_input)

    if value != "" and value not in socket.assigns.panel_ip_range_values do
      {:noreply,
       assign(socket,
         panel_ip_range_values: socket.assigns.panel_ip_range_values ++ [value],
         panel_ip_range_input: ""
       )}
    else
      {:noreply, assign(socket, panel_ip_range_input: "")}
    end
  end

  def handle_event("remove_ip_range_value", %{"range" => range}, socket) do
    {:noreply,
     assign(socket,
       panel_ip_range_values: List.delete(socket.assigns.panel_ip_range_values, range)
     )}
  end

  def handle_event("change_auth_provider_operator", %{"operator" => op}, socket) do
    {:noreply, assign(socket, panel_auth_provider_operator: op)}
  end

  def handle_event("toggle_auth_provider_value", %{"id" => id}, socket) do
    values = socket.assigns.panel_auth_provider_values

    updated = if id in values, do: List.delete(values, id), else: values ++ [id]

    {:noreply, assign(socket, panel_auth_provider_values: updated)}
  end

  def handle_info(%Change{old_struct: %Portal.Policy{}}, socket) do
    {:noreply, assign(socket, stale: true)}
  end

  def handle_info(%Change{struct: %Portal.Policy{}}, socket) do
    {:noreply, assign(socket, stale: true)}
  end

  def handle_info({:panel_change_resource, resource}, socket) do
    available = available_conditions(resource)
    filtered = Enum.filter(socket.assigns.panel_active_conditions, &(&1 in available))

    {:noreply,
     assign(socket, panel_selected_resource: resource, panel_active_conditions: filtered)}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  def on_panel_resource_change({_id, _name, resource}) do
    send(self(), {:panel_change_resource, resource})
  end

  defp new_policy(attrs, %Authentication.Subject{} = subject) do
    %Policy{}
    |> cast(attrs, ~w[description group_id resource_id]a)
    |> validate_required(~w[group_id resource_id]a)
    |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset/3)
    |> Policy.changeset()
    |> put_change(:account_id, subject.account.id)
  end

  defp create_policy(attrs, %Authentication.Subject{} = subject) do
    attrs
    |> new_policy(subject)
    |> Database.insert_policy(subject)
  end

  defp change_policy(%Policy{} = policy, attrs \\ %{}) do
    policy
    |> cast(attrs, ~w[description group_id resource_id]a)
    |> validate_required(~w[group_id resource_id]a)
    |> cast_embed(:conditions, with: &Portal.Policies.Condition.changeset/3)
    |> Policy.changeset()
  end

  defp disable_policy(%Policy{} = policy, %Authentication.Subject{} = subject) do
    changeset =
      policy
      |> change()
      |> put_default_value(:disabled_at, DateTime.utc_now())

    Database.update_policy(changeset, subject)
  end

  defp enable_policy(%Policy{} = policy, %Authentication.Subject{} = subject) do
    changeset =
      policy
      |> change()
      |> put_change(:disabled_at, nil)

    Database.update_policy(changeset, subject)
  end

  defp delete_policy(%Policy{} = policy, %Authentication.Subject{} = subject) do
    Database.delete_policy(policy, subject)
  end

  defp init_condition_assigns(%{conditions: conditions}) do
    find = fn prop -> Enum.find(conditions, &(&1.property == prop)) end
    loc = find.(:remote_ip_location_region)
    ip = find.(:remote_ip)
    auth = find.(:auth_provider_id)
    tod = find.(:current_utc_datetime)

    {tod_timezone, tod_values} = parse_tod_condition(tod)

    base = [
      panel_active_conditions: Enum.map(conditions, & &1.property),
      panel_conditions_dropdown_open: false,
      panel_location_search: "",
      panel_location_operator: cond_op(loc, "is_in"),
      panel_location_values: cond_values(loc),
      panel_ip_range_operator: cond_op(ip, "is_in_cidr"),
      panel_ip_range_values: cond_values(ip),
      panel_ip_range_input: "",
      panel_auth_provider_operator: cond_op(auth, "is_in"),
      panel_auth_provider_values: cond_values(auth),
      panel_tod_values: tod_values
    ]

    if tod_timezone, do: Keyword.put(base, :panel_timezone, tod_timezone), else: base
  end

  @spec parse_tod_condition(map() | nil) :: {String.t() | nil, map()}
  defp parse_tod_condition(nil), do: {nil, %{}}

  defp parse_tod_condition(%{values: values}) do
    parsed =
      Enum.flat_map(values, fn v ->
        case String.split(v, "/", parts: 3) do
          [day, ranges, tz] -> [{day, ranges, tz}]
          _ -> []
        end
      end)

    timezone =
      case parsed do
        [{_, _, tz} | _] -> tz
        _ -> nil
      end

    values_map = Map.new(parsed, fn {day, ranges, _tz} -> {day, ranges} end)
    {timezone, values_map}
  end

  defp cond_op(nil, default), do: default
  defp cond_op(cond, _default), do: to_string(cond.operator)

  defp cond_values(nil), do: []
  defp cond_values(cond), do: cond.values

  # ── Panel component ────────────────────────────────────────────────────────

  attr :account, :any, required: true
  attr :policy, :any, default: nil
  attr :providers, :list, default: []
  attr :subject, :any, required: true
  attr :panel_view, :atom, default: :list
  attr :panel_form, :any, default: nil
  attr :panel_selected_resource, :any, default: nil
  attr :panel_timezone, :string, default: "UTC"
  attr :panel_active_conditions, :list, default: []
  attr :panel_conditions_dropdown_open, :boolean, default: false
  attr :panel_location_search, :string, default: ""
  attr :panel_location_operator, :string, default: "is_in"
  attr :panel_location_values, :list, default: []
  attr :panel_ip_range_operator, :string, default: "is_in_cidr"
  attr :panel_ip_range_values, :list, default: []
  attr :panel_ip_range_input, :string, default: ""
  attr :panel_auth_provider_operator, :string, default: "is_in"
  attr :panel_auth_provider_values, :list, default: []
  attr :panel_tod_values, :map, default: %{}
  attr :confirm_disable_policy, :boolean, default: false
  attr :confirm_delete_policy, :boolean, default: false

  defp policy_panel(assigns) do
    ~H"""
    <div
      id="policy-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@policy || @panel_view in [:edit_form, :new_form],
          do: "translate-x-0",
          else: "translate-x-full"
        )
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <%!-- New policy form view --%>
      <div :if={@panel_view == :new_form} class="flex flex-col h-full overflow-hidden">
        <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-sm font-semibold text-[var(--text-primary)]">Add Policy</h2>
            <button
              phx-click="cancel_policy_form"
              class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
              title="Close (Esc)"
            >
              <.icon name="remix-close-line" class="w-4 h-4" />
            </button>
          </div>
        </div>
        <.form
          for={@panel_form}
          phx-submit="submit_policy_form"
          phx-change="change_policy_form"
          class="flex flex-col flex-1 min-h-0 overflow-hidden"
        >
          <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
            <div
              :if={@panel_form.errors[:base]}
              class="flex items-center gap-2 px-3 py-2.5 rounded-lg border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
            >
              <.icon
                name="remix-alert-line"
                class="w-4 h-4 shrink-0 text-[var(--status-error)]"
              />
              <p class="text-xs text-[var(--status-error)]">
                {translate_error(@panel_form.errors[:base])}
              </p>
            </div>
            <fieldset class="flex flex-col gap-4">
              <.live_component
                module={PortalWeb.Components.FormComponents.SelectWithGroups}
                id="panel_new_policy_group_id"
                label="Group"
                placeholder="Select Group"
                field={@panel_form[:group_id]}
                fetch_option_callback={&Database.fetch_group_option(&1, @subject)}
                list_options_callback={&Database.list_group_options(&1, @subject)}
                value={@panel_form[:group_id].value}
                required
              >
                <:options_group :let={options_group}>{options_group}</:options_group>
                <:option :let={group}>
                  <div class="flex items-center gap-2">
                    <.provider_icon type={provider_type_from_group(group)} class="w-4 h-4 shrink-0" />
                    <span>{group.name}</span>
                  </div>
                </:option>
                <:no_options :let={name}>
                  <.error data-validation-error-for={name}>No groups available.</.error>
                </:no_options>
                <:no_search_results>No groups found.</:no_search_results>
              </.live_component>

              <.live_component
                module={PortalWeb.Components.FormComponents.SelectWithGroups}
                id="panel_new_policy_resource_id"
                label="Resource"
                placeholder="Select Resource"
                field={@panel_form[:resource_id]}
                fetch_option_callback={
                  &PortalWeb.Resources.Components.fetch_resource_option(&1, @subject)
                }
                list_options_callback={
                  &PortalWeb.Resources.Components.list_resource_options(&1, @subject)
                }
                on_change={&on_panel_resource_change/1}
                value={@panel_form[:resource_id].value}
                required
              >
                <:options_group :let={group}>{group}</:options_group>
                <:option :let={resource}>
                  <%= if resource.type == :internet do %>
                    Internet
                  <% else %>
                    {resource.name}
                    <span :if={resource.site_id} class="text-[var(--text-tertiary)]">
                      ({resource.site.name})
                    </span>
                  <% end %>
                </:option>
                <:no_options :let={name}>
                  <.error data-validation-error-for={name}>No resources available.</.error>
                </:no_options>
                <:no_search_results>No resources found.</:no_search_results>
              </.live_component>

              <.input
                field={@panel_form[:description]}
                label="Description"
                type="textarea"
                placeholder="Enter an optional reason for creating this policy here."
                phx-debounce="300"
              />
            </fieldset>

            <div class="border-t border-[var(--border)] pt-4">
              <div class="flex items-center justify-between mb-3">
                <h4 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                  Conditions
                  <span class="ml-1 font-normal normal-case tracking-normal text-[var(--text-muted)]">
                    (optional)
                  </span>
                </h4>
                <div
                  :if={
                    not is_nil(@panel_selected_resource) and
                      available_conditions(@panel_selected_resource) -- @panel_active_conditions !=
                        []
                  }
                  class="relative"
                >
                  <button
                    type="button"
                    phx-click="toggle_conditions_dropdown"
                    class="flex items-center gap-1 px-2 py-1 rounded text-[10px] border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                  >
                    <.icon name="remix-add-line" class="w-2.5 h-2.5" /> Add condition
                  </button>
                  <div :if={@panel_conditions_dropdown_open}>
                    <div class="fixed inset-0 z-10" phx-click="toggle_conditions_dropdown"></div>
                    <div class="absolute right-0 top-full mt-1 z-20 min-w-44 rounded-lg border border-[var(--border-strong)] bg-[var(--surface-overlay)] shadow-lg py-1 overflow-hidden">
                      <button
                        :for={
                          type <-
                            available_conditions(@panel_selected_resource) --
                              @panel_active_conditions
                        }
                        type="button"
                        phx-click="add_condition"
                        phx-value-type={type}
                        class="w-full text-left px-3 py-1.5 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                      >
                        {condition_type_label(type)}
                      </button>
                    </div>
                  </div>
                </div>
              </div>
              <%= if is_nil(@panel_selected_resource) do %>
                <p class="text-xs text-[var(--text-muted)] text-center py-4 rounded-lg border border-dashed border-[var(--border)]">
                  Select a resource above to configure conditions
                </p>
              <% else %>
                <p
                  :if={@panel_active_conditions == []}
                  class="text-xs text-[var(--text-muted)] text-center py-4 rounded-lg border border-dashed border-[var(--border)]"
                >
                  No conditions — access is unrestricted
                </p>
                <div class="space-y-2">
                  <.grant_condition_card
                    :for={type <- @panel_active_conditions}
                    type={type}
                    providers={@providers}
                    timezone={@panel_timezone}
                    location_search={@panel_location_search}
                    location_operator={@panel_location_operator}
                    location_values={@panel_location_values}
                    ip_range_operator={@panel_ip_range_operator}
                    ip_range_values={@panel_ip_range_values}
                    ip_range_input={@panel_ip_range_input}
                    auth_provider_operator={@panel_auth_provider_operator}
                    auth_provider_values={@panel_auth_provider_values}
                    tod_values={@panel_tod_values}
                  />
                </div>
              <% end %>
            </div>
          </div>
          <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
            <button
              type="button"
              phx-click="cancel_policy_form"
              class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)]"
            >
              Create Policy
            </button>
          </div>
        </.form>
      </div>
      <%!-- Edit form view --%>
      <div :if={@panel_view == :edit_form} class="flex flex-col h-full overflow-hidden">
        <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-sm font-semibold text-[var(--text-primary)]">Edit Policy</h2>
            <button
              phx-click="cancel_policy_form"
              class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
              title="Close (Esc)"
            >
              <.icon name="remix-close-line" class="w-4 h-4" />
            </button>
          </div>
        </div>
        <.form
          for={@panel_form}
          phx-submit="submit_policy_form"
          phx-change="change_policy_form"
          class="flex flex-col flex-1 min-h-0 overflow-hidden"
        >
          <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
            <div
              :if={@panel_form.errors[:base]}
              class="flex items-center gap-2 px-3 py-2.5 rounded-lg border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
            >
              <.icon
                name="remix-alert-line"
                class="w-4 h-4 shrink-0 text-[var(--status-error)]"
              />
              <p class="text-xs text-[var(--status-error)]">
                {translate_error(@panel_form.errors[:base])}
              </p>
            </div>
            <fieldset class="flex flex-col gap-4">
              <.live_component
                module={PortalWeb.Components.FormComponents.SelectWithGroups}
                id="panel_policy_group_id"
                label="Group"
                placeholder="Select Group"
                field={@panel_form[:group_id]}
                fetch_option_callback={&Database.fetch_group_option(&1, @subject)}
                list_options_callback={&Database.list_group_options(&1, @subject)}
                value={@panel_form[:group_id].value}
                required
              >
                <:options_group :let={options_group}>{options_group}</:options_group>
                <:option :let={group}>
                  <div class="flex items-center gap-2">
                    <.provider_icon type={provider_type_from_group(group)} class="w-4 h-4 shrink-0" />
                    <span>{group.name}</span>
                  </div>
                </:option>
                <:no_options :let={name}>
                  <.error data-validation-error-for={name}>No groups available.</.error>
                </:no_options>
                <:no_search_results>No groups found.</:no_search_results>
              </.live_component>

              <.live_component
                module={PortalWeb.Components.FormComponents.SelectWithGroups}
                id="panel_policy_resource_id"
                label="Resource"
                placeholder="Select Resource"
                field={@panel_form[:resource_id]}
                fetch_option_callback={
                  &PortalWeb.Resources.Components.fetch_resource_option(&1, @subject)
                }
                list_options_callback={
                  &PortalWeb.Resources.Components.list_resource_options(&1, @subject)
                }
                on_change={&on_panel_resource_change/1}
                value={@panel_form[:resource_id].value}
                required
              >
                <:options_group :let={group}>{group}</:options_group>
                <:option :let={resource}>
                  <%= if resource.type == :internet do %>
                    Internet
                  <% else %>
                    {resource.name}
                    <span :if={resource.site_id} class="text-[var(--text-tertiary)]">
                      ({resource.site.name})
                    </span>
                  <% end %>
                </:option>
                <:no_options :let={name}>
                  <.error data-validation-error-for={name}>No resources available.</.error>
                </:no_options>
                <:no_search_results>No resources found.</:no_search_results>
              </.live_component>

              <.input
                field={@panel_form[:description]}
                label="Description"
                type="textarea"
                placeholder="Enter an optional reason for creating this policy here."
                phx-debounce="300"
              />
            </fieldset>

            <div
              :if={not is_nil(@panel_selected_resource)}
              class="border-t border-[var(--border)] pt-4"
            >
              <div class="flex items-center justify-between mb-3">
                <h4 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                  Conditions
                  <span class="ml-1 font-normal normal-case tracking-normal text-[var(--text-muted)]">
                    (optional)
                  </span>
                </h4>
                <div
                  :if={
                    available_conditions(@panel_selected_resource) -- @panel_active_conditions != []
                  }
                  class="relative"
                >
                  <button
                    type="button"
                    phx-click="toggle_conditions_dropdown"
                    class="flex items-center gap-1 px-2 py-1 rounded text-[10px] border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                  >
                    <.icon name="remix-add-line" class="w-2.5 h-2.5" /> Add condition
                  </button>
                  <div :if={@panel_conditions_dropdown_open}>
                    <div class="fixed inset-0 z-10" phx-click="toggle_conditions_dropdown"></div>
                    <div class="absolute right-0 top-full mt-1 z-20 min-w-44 rounded-lg border border-[var(--border-strong)] bg-[var(--surface-overlay)] shadow-lg py-1 overflow-hidden">
                      <button
                        :for={
                          type <-
                            available_conditions(@panel_selected_resource) --
                              @panel_active_conditions
                        }
                        type="button"
                        phx-click="add_condition"
                        phx-value-type={type}
                        class="w-full text-left px-3 py-1.5 text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                      >
                        {condition_type_label(type)}
                      </button>
                    </div>
                  </div>
                </div>
              </div>
              <p
                :if={@panel_active_conditions == []}
                class="text-xs text-[var(--text-muted)] text-center py-4 rounded-lg border border-dashed border-[var(--border)]"
              >
                No conditions — access is unrestricted
              </p>
              <div class="space-y-2">
                <.grant_condition_card
                  :for={type <- @panel_active_conditions}
                  type={type}
                  providers={@providers}
                  timezone={@panel_timezone}
                  location_search={@panel_location_search}
                  location_operator={@panel_location_operator}
                  location_values={@panel_location_values}
                  ip_range_operator={@panel_ip_range_operator}
                  ip_range_values={@panel_ip_range_values}
                  ip_range_input={@panel_ip_range_input}
                  auth_provider_operator={@panel_auth_provider_operator}
                  auth_provider_values={@panel_auth_provider_values}
                  tod_values={@panel_tod_values}
                />
              </div>
            </div>
          </div>
          <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
            <button
              type="button"
              phx-click="cancel_policy_form"
              class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)]"
            >
              Save Changes
            </button>
          </div>
        </.form>
      </div>
      <%!-- Detail view --%>
      <div :if={@policy && @panel_view == :list} class="flex flex-col h-full overflow-hidden">
        <%!-- Panel header --%>
        <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">
                <%= if @policy.group do %>
                  {@policy.group.name} — {@policy.resource.name}
                <% else %>
                  <span class="text-amber-600">(Group deleted)</span> — {@policy.resource.name}
                <% end %>
              </h2>
              <p class="font-mono text-xs text-[var(--text-tertiary)] mt-0.5">{@policy.id}</p>
            </div>
            <div class="flex items-center gap-1.5 shrink-0">
              <button
                phx-click="open_edit_form"
                class="flex items-center gap-1 px-2.5 py-1.5 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                <.icon name="remix-pencil-line" class="w-3.5 h-3.5" /> Edit
              </button>
              <button
                phx-click="close_panel"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="remix-close-line" class="w-4 h-4" />
              </button>
            </div>
          </div>
          <%!-- Stat strip --%>
          <div class="flex items-center gap-5 mt-3 pt-3 border-t border-[var(--border)]">
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Group
              </span>
              <span class="text-xs text-[var(--text-secondary)]">
                {if @policy.group, do: @policy.group.name, else: "—"}
              </span>
            </div>
            <div class="w-px h-3.5 bg-[var(--border-strong)]"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Resource
              </span>
              <span class="text-xs text-[var(--text-secondary)] truncate max-w-32">
                {@policy.resource.name}
              </span>
            </div>
            <div class="w-px h-3.5 bg-[var(--border-strong)]"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Conditions
              </span>
              <span class="text-xs font-semibold tabular-nums text-[var(--text-primary)]">
                {length(@policy.conditions)}
              </span>
            </div>
          </div>
        </div>

        <%!-- Panel body: two columns --%>
        <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
          <%!-- Left: Access mapping + conditions --%>
          <div class="flex-1 flex flex-col overflow-y-auto">
            <%!-- Access Mapping --%>
            <div class="px-5 pt-4 pb-4 border-b border-[var(--border)]">
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                  Access Mapping
                </h3>
              </div>
              <div class="flex items-stretch gap-2">
                <%!-- Group card --%>
                <%= if @policy.group do %>
                  <.link
                    navigate={~p"/#{@account}/groups/#{@policy.group}"}
                    class="flex-1 flex items-center gap-2.5 px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)] hover:border-[var(--border-emphasis)] hover:bg-[var(--surface)] transition-colors text-left group"
                  >
                    <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
                      <.provider_icon
                        type={provider_type_from_group(@policy.group)}
                        class="w-4 h-4"
                      />
                    </div>
                    <div class="min-w-0">
                      <p class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-0.5">
                        Group
                      </p>
                      <p class="text-sm font-medium text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors truncate">
                        {@policy.group.name}
                      </p>
                    </div>
                  </.link>
                <% else %>
                  <div class="flex-1 flex items-center gap-2.5 px-3 py-2.5 rounded border border-amber-200 bg-amber-50 dark:border-amber-900/30 dark:bg-amber-950/20">
                    <.icon name="remix-error-warning-line" class="w-5 h-5 text-amber-600 shrink-0" />
                    <div class="min-w-0">
                      <p class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-0.5">
                        Group
                      </p>
                      <p class="text-sm text-amber-600">Group deleted</p>
                    </div>
                  </div>
                <% end %>
                <%!-- Arrow --%>
                <div class="flex items-center shrink-0 text-[var(--text-muted)]">
                  <svg
                    class="w-4 h-4"
                    viewBox="0 0 16 16"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.5"
                    stroke-linecap="round"
                  >
                    <path d="M3 8h10M9 4l4 4-4 4" />
                  </svg>
                </div>
                <%!-- Resource card --%>
                <.link
                  navigate={~p"/#{@account}/resources/#{@policy.resource_id}"}
                  class="flex-1 flex items-center gap-2.5 px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)] hover:border-[var(--border-emphasis)] hover:bg-[var(--surface)] transition-colors text-left group"
                >
                  <span class={resource_type_badge_class(@policy.resource.type)}>
                    {@policy.resource.type}
                  </span>
                  <div class="min-w-0">
                    <p class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-0.5">
                      Resource
                    </p>
                    <p class="text-sm font-medium text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors truncate">
                      {@policy.resource.name}
                    </p>
                    <p class="font-mono text-xs text-[var(--text-tertiary)] truncate">
                      {@policy.resource.address}
                    </p>
                  </div>
                </.link>
              </div>
            </div>

            <%!-- Conditions --%>
            <div class="px-5 pt-4 pb-4">
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                  Conditions
                </h3>
              </div>
              <%= if @policy.conditions == [] do %>
                <p class="text-xs text-[var(--text-muted)]">
                  No conditions — access is always granted to group members.
                </p>
              <% else %>
                <ul class="space-y-2">
                  <%= for condition <- Enum.sort_by(@policy.conditions, &if(&1.property == :current_utc_datetime, do: 1, else: 0)) do %>
                    <li class="flex items-start gap-3 px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)]">
                      <span class={condition_type_badge_class(condition.property)}>
                        {condition_type_label(condition.property)}
                      </span>
                      <%= if condition.property == :current_utc_datetime do %>
                        <% {tz, rows} = tod_display_rows(condition.values) %>
                        <div class="flex-1 min-w-0 mt-0.5">
                          <div class="space-y-0.5">
                            <%= for {day, ranges} <- rows do %>
                              <div class="flex items-baseline gap-2">
                                <span class="text-[11px] font-medium text-[var(--text-secondary)] w-7 shrink-0">
                                  {day}
                                </span>
                                <span class="text-xs text-[var(--text-secondary)]">{ranges}</span>
                              </div>
                            <% end %>
                          </div>
                          <p class="text-[10px] text-[var(--text-muted)] mt-1">{tz}</p>
                        </div>
                      <% else %>
                        <span class="text-xs text-[var(--text-secondary)] flex-1 min-w-0 mt-0.5">
                          {condition_values_display(condition, @providers, @account)}
                        </span>
                      <% end %>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            </div>
          </div>

          <%!-- Right: Details + danger zone --%>
          <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
            <section>
              <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
                Details
              </h3>
              <dl class="space-y-2.5">
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Policy ID</dt>
                  <dd class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                    {@policy.id}
                  </dd>
                </div>
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Status</dt>
                  <dd>
                    <.status_badge status={
                      if is_nil(@policy.disabled_at), do: :active, else: :disabled
                    } />
                  </dd>
                </div>
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Created</dt>
                  <dd class="text-xs text-[var(--text-secondary)]">
                    <.relative_datetime datetime={@policy.inserted_at} />
                  </dd>
                </div>
                <div :if={@policy.description}>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Description</dt>
                  <dd class="text-xs text-[var(--text-secondary)]">{@policy.description}</dd>
                </div>
              </dl>
            </section>

            <div class="border-t border-[var(--border)]"></div>

            <section>
              <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
                Actions
              </h3>
              <div class="space-y-2">
                <button
                  :if={is_nil(@policy.disabled_at) and not @confirm_disable_policy}
                  type="button"
                  phx-click="confirm_disable_policy"
                  class="flex items-center gap-2 w-full px-3 py-2 rounded text-xs text-[var(--status-warning)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="remix-pause-line" class="w-3.5 h-3.5" /> Disable policy
                </button>
                <div
                  :if={is_nil(@policy.disabled_at) and @confirm_disable_policy}
                  class="px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)]"
                >
                  <p class="text-xs font-medium text-[var(--text-primary)] mb-1">
                    Disable this policy?
                  </p>
                  <p class="text-xs text-[var(--text-secondary)] mb-3">
                    This will immediately revoke all access granted by it.
                  </p>
                  <div class="flex items-center gap-1.5">
                    <button
                      type="button"
                      phx-click="cancel_disable_policy"
                      class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                    >
                      Cancel
                    </button>
                    <button
                      type="button"
                      phx-click="disable_policy"
                      class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors font-medium"
                    >
                      Disable
                    </button>
                  </div>
                </div>
                <button
                  :if={not is_nil(@policy.disabled_at)}
                  type="button"
                  phx-click="enable_policy"
                  class="flex items-center gap-2 w-full px-3 py-2 rounded text-xs text-[var(--status-active)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="remix-play-line" class="w-3.5 h-3.5" /> Enable policy
                </button>
              </div>
            </section>

            <div class="border-t border-[var(--border)]"></div>

            <section>
              <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--status-error)]/60 mb-3">
                Danger Zone
              </h3>
              <button
                :if={not @confirm_delete_policy}
                type="button"
                phx-click="confirm_delete_policy"
                class="w-full text-left px-3 py-2 rounded border border-[var(--status-error)]/20 text-xs text-[var(--status-error)] hover:bg-[var(--status-error-bg)] transition-colors"
              >
                Delete policy
              </button>
              <div
                :if={@confirm_delete_policy}
                class="px-3 py-2.5 rounded border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
              >
                <p class="text-xs font-medium text-[var(--status-error)] mb-1">
                  Delete this policy?
                </p>
                <p class="text-xs text-[var(--status-error)]/70 mb-3">
                  All sessions authorized by it will be expired.
                </p>
                <div class="flex items-center gap-1.5">
                  <button
                    type="button"
                    phx-click="cancel_delete_policy"
                    class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    phx-click="delete_policy"
                    class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </section>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  @spec condition_short_label(atom()) :: String.t()
  defp condition_short_label(:client_verified), do: "Verified"
  defp condition_short_label(:auth_provider_id), do: "Auth"
  defp condition_short_label(:remote_ip_location_region), do: "Location"
  defp condition_short_label(:remote_ip), do: "IP Range"
  defp condition_short_label(:current_utc_datetime), do: "Time"
  defp condition_short_label(_), do: "Condition"

  @spec condition_type_badge_class(atom()) :: String.t()
  defp condition_type_badge_class(:client_verified),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--status-active)] bg-[var(--status-active-bg)]"

  defp condition_type_badge_class(:auth_provider_id),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--badge-dns-text)] bg-[var(--badge-dns-bg)]"

  defp condition_type_badge_class(:remote_ip_location_region),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--badge-ip-text)] bg-[var(--badge-ip-bg)]"

  defp condition_type_badge_class(:remote_ip),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--badge-cidr-text)] bg-[var(--badge-cidr-bg)]"

  defp condition_type_badge_class(:current_utc_datetime),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--text-secondary)] bg-[var(--surface-raised)] border border-[var(--border)]"

  defp condition_type_badge_class(_),
    do:
      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium shrink-0 text-[var(--text-secondary)] bg-[var(--surface-raised)]"

  @spec condition_values_display(map(), list(), any()) :: String.t()
  defp condition_values_display(%{property: :client_verified}, _providers, _account) do
    "Client must be verified"
  end

  defp condition_values_display(
         %{property: :auth_provider_id, values: values},
         providers,
         _account
       ) do
    names =
      values
      |> Enum.map(fn id -> Enum.find(providers, &(&1.id == id)) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.name)

    if names == [], do: Enum.join(values, ", "), else: Enum.join(names, ", ")
  end

  defp condition_values_display(
         %{property: :remote_ip_location_region, values: values},
         _providers,
         _account
       ) do
    Enum.map_join(values, ", ", fn code ->
      try do
        Portal.Geo.country_common_name!(code)
      rescue
        _ -> code
      end
    end)
  end

  defp condition_values_display(%{property: :remote_ip, values: values}, _providers, _account) do
    Enum.join(values, ", ")
  end

  defp condition_values_display(
         %{property: :current_utc_datetime, values: values},
         _providers,
         _account
       ) do
    values
    |> Enum.map(fn v ->
      case String.split(v, "/", parts: 3) do
        [day, time_ranges, tz] when time_ranges != "" -> {day, time_ranges, tz}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(fn {_day, _ranges, tz} -> tz end)
    |> Enum.map_join("\n", fn {tz, entries} ->
      days_str =
        entries
        |> Enum.map(fn {day, ranges, _tz} ->
          "#{format_dow_abbr(day)} #{format_time_ranges(ranges)}"
        end)
        |> Enum.join(", ")

      "#{days_str} (#{tz})"
    end)
  end

  defp condition_values_display(%{values: values}, _providers, _account) do
    Enum.join(values, ", ")
  end

  @spec tod_display_rows([String.t()]) :: {String.t(), [{String.t(), String.t()}]}
  defp tod_display_rows(values) do
    parsed =
      Enum.flat_map(values, fn v ->
        case String.split(v, "/", parts: 3) do
          [day, ranges, tz] when ranges != "" -> [{day, ranges, tz}]
          _ -> []
        end
      end)

    timezone =
      case parsed do
        [{_, _, tz} | _] -> tz
        _ -> "UTC"
      end

    rows =
      Enum.map(parsed, fn {day, ranges, _tz} ->
        {format_dow_abbr(day), format_time_ranges(ranges)}
      end)

    {timezone, rows}
  end

  @spec format_dow_abbr(String.t()) :: String.t()
  defp format_dow_abbr("M"), do: "Mon"
  defp format_dow_abbr("T"), do: "Tue"
  defp format_dow_abbr("W"), do: "Wed"
  defp format_dow_abbr("R"), do: "Thu"
  defp format_dow_abbr("F"), do: "Fri"
  defp format_dow_abbr("S"), do: "Sat"
  defp format_dow_abbr("U"), do: "Sun"
  defp format_dow_abbr(d), do: d

  @spec format_time_ranges(String.t()) :: String.t()
  defp format_time_ranges("true"), do: "all day"

  defp format_time_ranges(ranges) do
    ranges
    |> String.split(",")
    |> Enum.map(fn range ->
      case String.split(range, "-") do
        [start, finish] -> "#{strip_seconds(start)}\u2013#{strip_seconds(finish)}"
        _ -> range
      end
    end)
    |> Enum.join(", ")
  end

  @spec strip_seconds(String.t()) :: String.t()
  defp strip_seconds(time) do
    case String.split(time, ":") do
      [h, m, _s] -> "#{h}:#{m}"
      _ -> time
    end
  end

  @spec resource_type_badge_class(atom()) :: String.t()
  defp resource_type_badge_class(:dns),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-dns-bg)] text-[var(--badge-dns-text)]"

  defp resource_type_badge_class(:ip),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-ip-bg)] text-[var(--badge-ip-text)]"

  defp resource_type_badge_class(:cidr),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--badge-cidr-bg)] text-[var(--badge-cidr-text)]"

  defp resource_type_badge_class(:internet),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-violet-100 text-violet-700 dark:bg-violet-900/30 dark:text-violet-300"

  defp resource_type_badge_class(_),
    do:
      "inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-mono font-medium tracking-wider uppercase bg-[var(--surface-raised)] text-[var(--text-secondary)]"

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Safe, Policy, Site, Resource, Group}
    alias Portal.Authentication

    def get_site(id, subject) do
      from(s in Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def get_resource(id, subject) do
      from(r in Resource, as: :resources)
      |> where([resources: r], r.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def get_policy(id, subject) do
      from(p in Policy, as: :policies)
      |> where([policies: p], p.id == ^id)
      |> preload(group: [:directory], resource: [])
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def insert_policy(changeset, %Authentication.Subject{} = subject) do
      changeset = populate_group_idp_id_for_insert(changeset, subject)

      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end

    defp populate_group_idp_id_for_insert(changeset, subject) do
      case Ecto.Changeset.get_field(changeset, :group_id) do
        nil ->
          changeset

        group_id ->
          idp_id = get_group_idp_id(group_id, subject)
          Ecto.Changeset.put_change(changeset, :group_idp_id, idp_id)
      end
    end

    def update_policy(changeset, %Authentication.Subject{} = subject) do
      changeset = populate_group_idp_id(changeset, subject)

      Safe.scoped(changeset, subject)
      |> Safe.update()
    end

    defp populate_group_idp_id(changeset, subject) do
      case Ecto.Changeset.get_change(changeset, :group_id) do
        nil ->
          changeset

        group_id ->
          idp_id = get_group_idp_id(group_id, subject)
          Ecto.Changeset.put_change(changeset, :group_idp_id, idp_id)
      end
    end

    defp get_group_idp_id(group_id, subject) do
      from(g in Group, where: g.id == ^group_id, select: g.idp_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
    end

    def fetch_group_option(id, subject) do
      group =
        from(g in Group, as: :groups)
        |> where([groups: g], g.id == ^id)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
        |> join(:left, [directory: d], gd in Portal.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Portal.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Portal.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name: fragment("COALESCE(?, ?, ?)", gd.name, ed.name, od.name),
            directory_type: d.type
          }
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.one!(fallback_to_primary: true)

      {:ok, {group.id, group.name, group}}
    end

    def list_group_options(search_query_or_nil, subject) do
      query =
        from(g in Group, as: :groups)
        |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
        |> join(:left, [directory: d], gd in Portal.Google.Directory,
          on: gd.id == d.id and d.type == :google,
          as: :google_directory
        )
        |> join(:left, [directory: d], ed in Portal.Entra.Directory,
          on: ed.id == d.id and d.type == :entra,
          as: :entra_directory
        )
        |> join(:left, [directory: d], od in Portal.Okta.Directory,
          on: od.id == d.id and d.type == :okta,
          as: :okta_directory
        )
        |> select_merge(
          [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
          %{
            directory_name: fragment("COALESCE(?, ?, ?)", gd.name, ed.name, od.name),
            directory_type: d.type
          }
        )
        |> order_by([groups: g], asc: g.name)
        |> limit(25)

      query =
        if search_query_or_nil in ["", nil] do
          query
        else
          from(g in query, where: fulltext_search(g.name, ^search_query_or_nil))
        end

      groups = query |> Safe.scoped(subject, :replica) |> Safe.all()
      metadata = %{limit: 25, count: length(groups)}

      {:ok, grouped_select_options(groups), metadata}
    end

    defp grouped_select_options(groups) do
      groups
      |> Enum.group_by(&option_group_label/1)
      |> Enum.sort_by(fn {{idx, _label}, _} -> idx end)
      |> Enum.map(fn {{_idx, label}, grps} ->
        {label, grps |> Enum.sort_by(& &1.name) |> Enum.map(&{&1.id, &1.name, &1})}
      end)
    end

    defp option_group_label(group) do
      cond do
        not is_nil(group.idp_id) -> {9, "Synced from #{directory_display_name(group)}"}
        group.type == :managed -> {1, "Managed by Firezone"}
        true -> {2, "Manually managed"}
      end
    end

    defp directory_display_name(%{directory_name: name}) when not is_nil(name), do: name
    defp directory_display_name(_), do: "Unknown"

    def delete_policy(%Policy{} = policy, %Authentication.Subject{} = subject) do
      Safe.scoped(policy, subject)
      |> Safe.delete()
    end

    def all_active_providers(_account, subject) do
      [
        Portal.Userpass.AuthProvider,
        Portal.EmailOTP.AuthProvider,
        Portal.OIDC.AuthProvider,
        Portal.Google.AuthProvider,
        Portal.Entra.AuthProvider,
        Portal.Okta.AuthProvider
      ]
      |> Enum.flat_map(fn schema ->
        from(p in schema, where: not p.is_disabled)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
      end)
    end

    def list_policies(subject, opts \\ []) do
      from(p in Policy, as: :policies)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    # Pagination support
    def cursor_fields,
      do: [
        {:policies, :asc, :inserted_at},
        {:policies, :asc, :id}
      ]

    def filters do
      [
        %Portal.Repo.Filter{
          name: :resource_id,
          title: "Resource",
          type: {:string, :uuid},
          fun: &filter_by_resource_id/2
        },
        %Portal.Repo.Filter{
          name: :site_id,
          title: "Site",
          type: {:string, :uuid},
          fun: &filter_by_site_id/2
        },
        %Portal.Repo.Filter{
          name: :group_id,
          title: "Group",
          type: {:string, :uuid},
          fun: &filter_by_group_id/2
        },
        %Portal.Repo.Filter{
          name: :group_name,
          title: "Group Name",
          type: {:string, :websearch},
          fun: &filter_by_group_name/2
        },
        %Portal.Repo.Filter{
          name: :resource_name,
          title: "Resource Name",
          type: {:string, :websearch},
          fun: &filter_by_resource_name/2
        },
        %Portal.Repo.Filter{
          name: :group_or_resource,
          title: "Group or Resource",
          type: {:string, :websearch},
          fun: &filter_by_group_or_resource/2
        },
        %Portal.Repo.Filter{
          name: :status,
          title: "Status",
          type: :string,
          values: [
            {"Active", "active"},
            {"Disabled", "disabled"}
          ],
          fun: &filter_by_status/2
        }
      ]
    end

    def filter_by_resource_id(queryable, resource_id) do
      {queryable, dynamic([policies: p], p.resource_id == ^resource_id)}
    end

    def filter_by_site_id(queryable, site_id) do
      queryable = with_joined_resource(queryable)
      {queryable, dynamic([resource: r], r.site_id == ^site_id)}
    end

    def filter_by_group_id(queryable, group_id) do
      {queryable, dynamic([policies: p], p.group_id == ^group_id)}
    end

    def filter_by_group_name(queryable, name) do
      queryable = with_joined_group(queryable)
      {queryable, dynamic([group: g], fulltext_search(g.name, ^name))}
    end

    def filter_by_resource_name(queryable, name) do
      queryable = with_joined_resource(queryable)
      {queryable, dynamic([resource: r], fulltext_search(r.name, ^name))}
    end

    def filter_by_group_or_resource(queryable, search_term) do
      queryable = queryable |> with_joined_group() |> with_joined_resource()

      {queryable,
       dynamic(
         [group: g, resource: r],
         fulltext_search(g.name, ^search_term) or
           fulltext_search(r.name, ^search_term) or
           fulltext_search(r.address, ^search_term)
       )}
    end

    def filter_by_status(queryable, "active") do
      {queryable, dynamic([policies: p], is_nil(p.disabled_at))}
    end

    def filter_by_status(queryable, "disabled") do
      {queryable, dynamic([policies: p], not is_nil(p.disabled_at))}
    end

    defp with_joined_group(queryable) do
      if has_named_binding?(queryable, :group) do
        queryable
      else
        join(queryable, :left, [policies: p], g in assoc(p, :group), as: :group)
      end
    end

    defp with_joined_resource(queryable) do
      if has_named_binding?(queryable, :resource) do
        queryable
      else
        join(queryable, :inner, [policies: p], r in assoc(p, :resource), as: :resource)
      end
    end
  end
end
