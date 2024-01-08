defmodule Web.Policies.Index do
  use Web, :live_view
  alias Domain.Policies

  def mount(_params, _session, socket) do
    with {:ok, policies} <-
           Policies.list_policies(socket.assigns.subject, preload: [:actor_group, :resource]) do
      socket = assign(socket, policies: policies, page_title: "Policies")
      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
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
            <.badge>
              <%= policy.actor_group.name %>
            </.badge>
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
end
