defmodule Web.Policies.Index do
  use Web, :live_view
  alias Domain.Policies

  def mount(_params, _session, socket) do
    with {:ok, socket} <- load_policies_with_assocs(socket) do
      :ok = Policies.subscribe_to_events_for_account(socket.assigns.account)
      {:ok, assign(socket, page_title: "Policies")}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  defp load_policies_with_assocs(socket) do
    with {:ok, policies} <-
           Policies.list_policies(socket.assigns.subject,
             preload: [actor_group: [:provider], resource: []]
           ) do
      {:ok, assign(socket, policies: policies)}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/policies"}><%= @page_title %></.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title><%= @page_title %></:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/policies/new"}>
          Add Policy
        </.add_button>
      </:action>
      <:content>
        <.table id="policies" rows={@policies} row_id={&"policies-#{&1.id}"}>
          <:col :let={policy} label="ID">
            <.link class={link_style()} navigate={~p"/#{@account}/policies/#{policy}"}>
              <%= policy.id %>
            </.link>
          </:col>
          <:col :let={policy} label="GROUP">
            <.group account={@account} group={policy.actor_group} />
          </:col>
          <:col :let={policy} label="RESOURCE">
            <.link class={link_style()} navigate={~p"/#{@account}/resources/#{policy.resource_id}"}>
              <%= policy.resource.name %>
            </.link>
          </:col>
          <:col :let={policy} label="STATUS">
            <%= if is_nil(policy.deleted_at) do %>
              <%= if is_nil(policy.disabled_at) do %>
                Active
              <% else %>
                Disabled
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
                to grant access to a resource.
              </div>
            </div>
          </:empty>
        </.table>
      </:content>
    </.section>
    """
  end

  def handle_info({:create_policy, _policy_id}, socket) do
    {:ok, socket} = load_policies_with_assocs(socket)
    {:noreply, socket}
  end

  def handle_info({_action, policy_id}, socket) do
    if Enum.find(socket.assigns.policies, fn policy -> policy.id == policy_id end) do
      {:ok, socket} = load_policies_with_assocs(socket)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end
end
