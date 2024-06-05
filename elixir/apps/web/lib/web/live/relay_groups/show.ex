defmodule Web.RelayGroups.Show do
  use Web, :live_view
  alias Domain.{Accounts, Relays, Tokens}

  def mount(%{"id" => id}, _session, socket) do
    with true <- Accounts.self_hosted_relays_enabled?(socket.assigns.account),
         {:ok, group} <-
           Relays.fetch_group_by_id(id, socket.assigns.subject,
             preload: [
               created_by_identity: [:actor]
             ]
           ) do
      if connected?(socket) do
        :ok = Relays.subscribe_to_relays_presence_in_group(group)
      end

      socket =
        socket
        |> assign(
          page_title: "Relay Group #{group.name}",
          group: group
        )
        |> assign_live_table("relays",
          query_module: Relays.Relay.Query,
          enforce_filters: [
            {:relay_group_id, group.id}
          ],
          sortable_fields: [
            {:relays, :name},
            {:relays, :last_seen_at}
          ],
          callback: &handle_relays_update!/2
        )

      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_relays_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:online?])

    with {:ok, relays, metadata} <- Relays.list_relays(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         relays: relays,
         relays_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/relay_groups"}>Relay Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Relay Instance Group: <code><%= @group.name %></code>
        <span :if={not is_nil(@group.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={not is_nil(@group.account_id) and is_nil(@group.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/relay_groups/#{@group}/edit"}>
          Edit Instance Group
        </.edit_button>
      </:action>
      <:content>
        <div class="bg-white overflow-hidden">
          <.vertical_table id="group">
            <.vertical_table_row>
              <:label>Instance Group Name</:label>
              <:value><%= @group.name %></:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Created</:label>
              <:value>
                <.created_by account={@account} schema={@group} />
              </:value>
            </.vertical_table_row>
          </.vertical_table>
        </div>
      </:content>
    </.section>

    <.section>
      <:title>Relays</:title>
      <:action :if={not is_nil(@group.account_id) and is_nil(@group.deleted_at)}>
        <.add_button navigate={~p"/#{@account}/relay_groups/#{@group}/new_token"}>
          Deploy
        </.add_button>
      </:action>
      <:action :if={is_nil(@group.deleted_at)}>
        <.delete_button
          phx-click="revoke_all_tokens"
          data-confirm="Are you sure you want to revoke all tokens? This will immediately sign the actor out of all clients."
        >
          Revoke All Tokens
        </.delete_button>
      </:action>
      <:content flash={@flash}>
        <div class="relative overflow-x-auto">
          <.live_table
            id="relays"
            rows={@relays}
            filters={@filters_by_table_id["relays"]}
            filter={@filter_form_by_table_id["relays"]}
            ordered_by={@order_by_table_id["relays"]}
            metadata={@relays_metadata}
          >
            <:col :let={relay} label="INSTANCE">
              <.link navigate={~p"/#{@account}/relays/#{relay.id}"} class={[link_style()]}>
                <code :if={relay.name} class="block text-xs">
                  <%= relay.name %>
                </code>
                <code :if={relay.ipv4} class="block text-xs">
                  <%= relay.ipv4 %>
                </code>
                <code :if={relay.ipv6} class="block text-xs">
                  <%= relay.ipv6 %>
                </code>
              </.link>
            </:col>
            <:col :let={relay} label="STATUS">
              <.connection_status schema={relay} />
            </:col>
            <:empty>
              <div class="text-center text-neutral-500 p-4">No relay instances to display</div>
            </:empty>
          </.live_table>
        </div>
      </:content>
    </.section>

    <.danger_zone :if={not is_nil(@group.account_id) and is_nil(@group.deleted_at)}>
      <:action :if={@group.account_id}>
        <.delete_button
          phx-click="delete"
          data-confirm="Are you sure want to delete this relay group and disconnect all it's relays?"
        >
          Delete Instance Group
        </.delete_button>
      </:action>
    </.danger_zone>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:" <> _rest},
        socket
      ) do
    {:noreply, reload_live_table!(socket, "relays")}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("revoke_all_tokens", _params, socket) do
    group = socket.assigns.group
    {:ok, deleted_tokens} = Tokens.delete_tokens_for(group, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:info, "#{length(deleted_tokens)} token(s) were revoked.")

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _group} = Relays.delete_group(socket.assigns.group, socket.assigns.subject)
    {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/relay_groups")}
  end
end
