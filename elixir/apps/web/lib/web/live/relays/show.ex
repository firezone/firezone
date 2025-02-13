defmodule Web.Relays.Show do
  use Web, :live_view
  alias Domain.{Accounts, Relays}

  def mount(%{"id" => id}, _session, socket) do
    with true <- Accounts.self_hosted_relays_enabled?(socket.assigns.account),
         {:ok, relay} <-
           Relays.fetch_relay_by_id(id, socket.assigns.subject, preload: [:group, :online?]) do
      if connected?(socket) do
        :ok = Relays.subscribe_to_relays_presence_in_group(relay.group)
      end

      socket =
        assign(socket,
          page_title: "Relay #{relay.name}",
          relay: relay
        )

      {:ok, socket}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/relay_groups"}>Relay Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/#{@relay.group}"}>
        {@relay.group.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relays/#{@relay}"}>
        {@relay.name || @relay.ipv4 || @relay.ipv6}
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Relay: <span :if={@relay.name}>{@relay.name}</span>
        <.intersperse_blocks :if={is_nil(@relay.name)}>
          <:separator>,&nbsp;</:separator>

          <:item :for={ip <- [@relay.ipv4, @relay.ipv6]} :if={not is_nil(ip)}>
            <code>{@relay.ipv4}</code>
          </:item>
        </.intersperse_blocks>
        <span :if={not is_nil(@relay.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:content>
        <div class="bg-white overflow-hidden">
          <.vertical_table id="relay">
            <.vertical_table_row>
              <:label>Instance Group Name</:label>
              <:value>{@relay.group.name}</:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Name</:label>
              <:value>{@relay.name}</:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>
                IPv4
                <p class="text-xs">Set by <code>PUBLIC_IP4_ADDR</code></p>
              </:label>
              <:value>
                <code>{@relay.ipv4}</code>
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>
                IPv6
                <p class="text-xs">Set by <code>PUBLIC_IP6_ADDR</code></p>
              </:label>
              <:value>
                <code>{@relay.ipv6}</code>
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Status</:label>
              <:value>
                <.connection_status schema={@relay} />
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>
                Last started
              </:label>
              <:value>
                <.relative_datetime datetime={@relay.last_seen_at} />
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Last seen remote IP</:label>
              <:value>
                <.last_seen schema={@relay} />
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>Version</:label>
              <:value>
                {@relay.last_seen_version}
              </:value>
            </.vertical_table_row>
            <.vertical_table_row>
              <:label>User agent</:label>
              <:value>
                {@relay.last_seen_user_agent}
              </:value>
            </.vertical_table_row>
          </.vertical_table>
        </div>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@relay.deleted_at)}>
      <:action :if={@relay.account_id}>
        <.button_with_confirmation
          id="delete_relay"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
        >
          <:dialog_title>Confirm deletion of Relay</:dialog_title>
          <:dialog_content>
            <p>
              Are you sure you want to delete this relay?
            </p>
            <p class="mt-4 text-sm">
              Deleting the relay does not remove it's access token so it can be re-created again,
              revoke the token on the
              <.link
                navigate={~p"/#{@account}/relay_groups/#{@relay.group}"}
                class={["font-medium", link_style()]}
              >
                instance group
              </.link>
              page if you want to prevent the gateway from connecting to the portal.
            </p>
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Relay
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete Relay
        </.button_with_confirmation>
      </:action>
    </.danger_zone>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "presences:group_relays:" <> _group_id,
          payload: payload
        },
        socket
      ) do
    relay = socket.assigns.relay

    socket =
      cond do
        Map.has_key?(payload.joins, relay.id) ->
          {:ok, relay} =
            Relays.fetch_relay_by_id(relay.id, socket.assigns.subject, preload: [:group])

          assign(socket, relay: %{relay | online?: true})

        Map.has_key?(payload.leaves, relay.id) ->
          assign(socket, relay: %{relay | online?: false})

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _relay} = Relays.delete_relay(socket.assigns.relay, socket.assigns.subject)

    socket =
      push_navigate(socket,
        to: ~p"/#{socket.assigns.account}/relay_groups/#{socket.assigns.relay.group}"
      )

    {:noreply, socket}
  end
end
