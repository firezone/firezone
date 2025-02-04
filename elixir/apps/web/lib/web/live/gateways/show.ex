defmodule Web.Gateways.Show do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, gateway} <-
           Gateways.fetch_gateway_by_id(id, socket.assigns.subject, preload: [:group, :online?]) do
      if connected?(socket) do
        :ok = Gateways.subscribe_to_gateways_presence_in_group(gateway.group)
      end

      socket =
        socket
        |> assign(
          page_title: "Gateway #{gateway.name}",
          gateway: gateway
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway.group}"}>
        {@gateway.group.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway.group}/gateways"}>
        Gateways
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateways/#{@gateway}"}>
        {@gateway.name}
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Gateway: <code>{@gateway.name}</code>
        <span :if={not is_nil(@gateway.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:content>
        <.vertical_table id="gateway">
          <.vertical_table_row>
            <:label>Site</:label>
            <:value>
              <.link
                navigate={~p"/#{@account}/sites/#{@gateway.group}"}
                class={["font-medium", link_style()]}
              >
                {@gateway.group.name}
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Name</:label>
            <:value>{@gateway.name}</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Status</:label>
            <:value>
              <.connection_status schema={@gateway} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>
              Last started
            </:label>
            <:value>
              <.relative_datetime datetime={@gateway.last_seen_at} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Last seen remote IP</:label>
            <:value>
              <.last_seen schema={@gateway} />
            </:value>
          </.vertical_table_row>
          <!--
        <.vertical_table_row>
          <:label>Transfer</:label>
          <:value>TODO: 4.43 GB up, 1.23 GB down</:value>
        </.vertical_table_row>
        -->
          <.vertical_table_row>
            <:label>Version</:label>
            <:value>
              {@gateway.last_seen_version}
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>User agent</:label>
            <:value>
              {@gateway.last_seen_user_agent}
            </:value>
          </.vertical_table_row>
          <!--
        <.vertical_table_row>
          <:label>Deployment Method</:label>
          <:value>TODO: Docker</:value>
        </.vertical_table_row>
        -->
        </.vertical_table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@gateway.deleted_at)}>
      <:action>
        <.button_with_confirmation
          id="delete_gateway"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
        >
          <:dialog_title>Confirm deletion of Gateway</:dialog_title>
          <:dialog_content>
            Deleting the gateway does not remove it's access token so it can be re-created again,
            revoke the token on the
            <.link
              navigate={~p"/#{@account}/sites/#{@gateway.group}"}
              class={["font-medium", link_style()]}
            >
              site
            </.link>
            page if you want to prevent the gateway from connecting to the portal.
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Gateway
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete Gateway
        </.button_with_confirmation>
      </:action>
    </.danger_zone>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "presences:group_gateways:" <> _group_id,
          payload: payload
        },
        socket
      ) do
    gateway = socket.assigns.gateway

    socket =
      cond do
        Map.has_key?(payload.joins, gateway.id) ->
          {:ok, gateway} =
            Gateways.fetch_gateway_by_id(gateway.id, socket.assigns.subject, preload: [:group])

          assign(socket, gateway: %{gateway | online?: true})

        Map.has_key?(payload.leaves, gateway.id) ->
          assign(socket, gateway: %{gateway | online?: false})

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _gateway} = Gateways.delete_gateway(socket.assigns.gateway, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:info, "Gateway was deleted.")
      |> push_navigate(to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.gateway.group}")

    {:noreply, socket}
  end
end
