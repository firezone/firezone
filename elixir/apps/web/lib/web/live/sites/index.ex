defmodule Web.Sites.Index do
  use Web, :live_view
  alias Domain.Gateways

  def mount(_params, _session, socket) do
    subject = socket.assigns.subject

    with {:ok, groups} <-
           Gateways.list_groups(subject, preload: [:gateways, connections: [:resource]]) do
      :ok = Gateways.subscribe_for_gateways_presence_in_account(socket.assigns.account)
      {:ok, assign(socket, groups: groups)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Sites
      </:title>
      <:action>
        <.add_button navigate={~p"/#{@account}/sites/new"}>
          Add Site
        </.add_button>
      </:action>
      <:content>
        <.table id="groups" rows={@groups} row_id={&"group-#{&1.id}"}>
          <:col :let={group} label="site">
            <.link
              navigate={~p"/#{@account}/sites/#{group}"}
              class="font-bold text-blue-600 dark:text-blue-500 hover:underline"
            >
              <%= group.name_prefix %>
            </.link>
          </:col>

          <:col :let={group} label="resources">
            <% connections = Enum.reject(group.connections, &is_nil(&1.resource))
            peek = %{count: length(connections), items: Enum.take(connections, 5)} %>
            <.peek peek={peek}>
              <:empty>
                None
              </:empty>

              <:separator>
                <span class="pr-1">,</span>
              </:separator>

              <:item :let={connection}>
                <.link
                  navigate={~p"/#{@account}/resources/#{connection.resource}"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline inline-block"
                  phx-no-format
                ><%= connection.resource.name %></.link>
              </:item>

              <:tail :let={count}>
                <span class="pl-1">
                  and
                  <.link
                    navigate={~p"/#{@account}/sites/#{group}?#resources"}
                    class="font-bold text-blue-600 dark:text-blue-500 hover:underline"
                  >
                    <%= count %> more.
                  </.link>
                </span>
              </:tail>
            </.peek>
          </:col>

          <:col :let={group} label="gateways">
            <% peek = %{count: length(group.gateways), items: Enum.take(group.gateways, 5)} %>
            <.peek peek={peek}>
              <:empty>
                None
              </:empty>

              <:separator>
                <span class="pr-1">,</span>
              </:separator>

              <:item :let={gateway}>
                <.link
                  navigate={~p"/#{@account}/gateways/#{gateway}"}
                  class="font-medium text-blue-600 dark:text-blue-500 hover:underline inline-block"
                  phx-no-format
                ><%= gateway.name_suffix %></.link>
              </:item>

              <:tail :let={count}>
                <span class="pl-1">
                  and
                  <.link
                    navigate={~p"/#{@account}/sites/#{group}?#gateways"}
                    class="font-bold text-blue-600 dark:text-blue-500 hover:underline"
                  >
                    <%= count %> more.
                  </.link>
                </span>
              </:tail>
            </.peek>
          </:col>

          <:empty>
            <div class="flex justify-center text-center text-slate-500 p-4">
              <div class="w-auto">
                <div class="pb-4">
                  No sites to display
                </div>
                <.add_button navigate={~p"/#{@account}/sites/new"}>
                  Add Site
                </.add_button>
              </div>
            </div>
          </:empty>
        </.table>
      </:content>
    </.section>
    """
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "gateways:" <> _account_id}, socket) do
    subject = socket.assigns.subject
    {:ok, groups} = Gateways.list_groups(subject, preload: [:gateways, connections: [:resource]])
    {:noreply, assign(socket, groups: groups)}
  end
end
