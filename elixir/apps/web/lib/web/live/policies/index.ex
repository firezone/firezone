defmodule Web.Policies.Index do
  use Web, :live_view
  alias Domain.Policies

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Policies.subscribe_to_events_for_account(socket.assigns.account)
    end

    socket =
      socket
      |> assign(page_title: "Policies")
      |> assign_live_table("policies",
        query_module: Policies.Policy.Query,
        sortable_fields: [],
        hide_filters: [
          :actor_group_id,
          :actor_group_name,
          :resource_id,
          :resource_name
        ],
        callback: &handle_policies_update!/2
      )

    {:ok, socket}
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_policies_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, actor_group: [:provider], resource: [])

    with {:ok, policies, metadata} <- Policies.list_policies(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         policies: policies,
         policies_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/policies"}>{@page_title}</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>{@page_title}</:title>
      <:action>
        <.docs_action path="/deploy/policies" />
      </:action>
      <:action>
        <.add_button navigate={~p"/#{@account}/policies/new"}>
          Add Policy
        </.add_button>
      </:action>
      <:help>
        Policies grant access to Resources.
      </:help>
      <:content>
        <.flash_group flash={@flash} />
        <.live_table
          id="policies"
          rows={@policies}
          row_id={&"policies-#{&1.id}"}
          filters={@filters_by_table_id["policies"]}
          filter={@filter_form_by_table_id["policies"]}
          ordered_by={@order_by_table_id["policies"]}
          metadata={@policies_metadata}
        >
          <:col :let={policy} label="id" class="w-3/12">
            <.link class={link_style()} navigate={~p"/#{@account}/policies/#{policy}"}>
              <span class="block truncate">
                {policy.id}
              </span>
            </.link>
          </:col>
          <:col :let={policy} label="group" class="w-3/12">
            <span class="flex items-center">
              <.group account={@account} group={policy.actor_group} />
            </span>
          </:col>
          <:col :let={policy} label="resource" class="w-2/12">
            <.link class={link_style()} navigate={~p"/#{@account}/resources/#{policy.resource_id}"}>
              {policy.resource.name}
            </.link>
          </:col>
          <:col :let={policy} label="status">
            <%= if is_nil(policy.deleted_at) do %>
              <%= if is_nil(policy.disabled_at) do %>
                Active
              <% else %>
                <span class="text-red-800">Disabled</span>
              <% end %>
            <% else %>
              Deleted
            <% end %>
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="pb-4 w-auto">
                No policies to display.
                <.link class={[link_style()]} navigate={~p"/#{@account}/policies/new"}>
                  Add a policy
                </.link>
                to grant access to Resources.
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

  def handle_info({:create_policy, _policy_id}, socket) do
    {:noreply, socket}
  end

  def handle_info({:delete_policy, policy_id}, socket) do
    if Enum.find(socket.assigns.policies, fn policy -> policy.id == policy_id end) do
      policies =
        Enum.filter(socket.assigns.policies, fn
          policy -> policy.id != policy_id
        end)

      {:noreply, assign(socket, policies: policies)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({_action, _policy_id}, socket) do
    socket = reload_live_table!(socket, "policies")
    {:noreply, socket}
  end
end
