defmodule PortalWeb.Gateways.Show do
  use PortalWeb, :live_view
  alias Portal.Presence
  alias __MODULE__.Database

  def mount(%{"id" => id}, _session, socket) do
    gateway = Database.get_gateway!(id, socket.assigns.subject)
    gateway = Database.preload_gateways_presence([gateway]) |> List.first()

    if connected?(socket) do
      :ok = Presence.Gateways.Site.subscribe(gateway.site_id)
    end

    socket =
      socket
      |> assign(
        page_title: "Gateway #{gateway.name}",
        gateway: gateway
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway.site}"}>
        {@gateway.site.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@gateway.site}/gateways"}>
        Gateways
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateways/#{@gateway}"}>
        {@gateway.name}
      </.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title>
        Gateway: <code>{@gateway.name}</code>
      </:title>
      <:content>
        <.vertical_table id="gateway">
          <.vertical_table_row>
            <:label>Site</:label>
            <:value>
              <.link
                navigate={~p"/#{@account}/sites/#{@gateway.site}"}
                class={["font-medium", link_style()]}
              >
                {@gateway.site.name}
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
          <.vertical_table_row>
            <:label>Tunnel Interface IPv4 Address</:label>
            <:value>{@gateway.ipv4_address.address}</:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Tunnel Interface IPv6 Address</:label>
            <:value>{@gateway.ipv6_address.address}</:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.danger_zone>
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
              navigate={~p"/#{@account}/sites/#{@gateway.site}"}
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
          topic: "presences:sites:" <> _site_id,
          payload: payload
        },
        socket
      ) do
    gateway = socket.assigns.gateway

    socket =
      cond do
        Map.has_key?(payload.joins, gateway.id) ->
          gateway = Database.get_gateway!(gateway.id, socket.assigns.subject)
          assign(socket, gateway: %{gateway | online?: true})

        Map.has_key?(payload.leaves, gateway.id) ->
          assign(socket, gateway: %{gateway | online?: false})

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _gateway} = Database.delete_gateway(socket.assigns.gateway, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:success, "Gateway was deleted.")
      |> push_navigate(to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.gateway.site}")

    {:noreply, socket}
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Gateway

    def get_gateway!(id, subject) do
      from(g in Gateway, as: :gateways)
      |> where([gateways: g], g.id == ^id)
      |> preload([:site, :ipv4_address, :ipv6_address])
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def delete_gateway(gateway, subject) do
      Safe.scoped(gateway, subject)
      |> Safe.delete()
    end

    def preload_gateways_presence(gateways) do
      Presence.Gateways.preload_gateways_presence(gateways)
    end
  end
end
