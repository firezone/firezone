defmodule Web.Clients.Show do
  use Web, :live_view
  import Web.Policies.Components
  import Web.Clients.Components
  alias Domain.{Accounts, Clients, Flows}

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, client} <-
           Clients.fetch_client_by_id(id, socket.assigns.subject,
             preload: [
               :online?,
               :actor,
               :verified_by_identity,
               :verified_by_actor,
               last_used_token: [identity: [:provider]]
             ]
           ) do
      if connected?(socket) do
        :ok = Clients.subscribe_to_clients_presence_for_actor(client.actor)
      end

      socket =
        assign(
          socket,
          client: client,
          flow_activities_enabled?: Accounts.flow_activities_enabled?(socket.assigns.account),
          page_title: "Client #{client.name}"
        )
        |> assign_live_table("flows",
          query_module: Flows.Flow.Query,
          sortable_fields: [],
          hide_filters: [:expiration],
          callback: &handle_flows_update!/2
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_flows_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload,
        client: [:actor],
        gateway: [:group],
        policy: [:actor_group, :resource]
      )

    with {:ok, flows, metadata} <-
           Flows.list_flows_for(socket.assigns.client, socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         flows: flows,
         flows_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/clients"}>Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/clients/#{@client.id}"}>
        <%= @client.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Client Details
        <span :if={not is_nil(@client.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>

      <:action :if={is_nil(@client.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/clients/#{@client}/edit"}>
          Edit Client
        </.edit_button>
      </:action>

      <:content>
        <.vertical_table id="client">
          <.vertical_table_row>
            <:label>
              <.popover>
                <:target>
                  ID <.icon name="hero-question-mark-circle" class="w-3 h-3 mb-1 text-neutral-400" />
                </:target>
                <:content>
                  Database ID assigned to this Client that can be used to manage this Client via the REST API.
                </:content>
              </.popover>
            </:label>
            <:value><%= @client.id %></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Name</:label>
            <:value><%= @client.name %></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Status</:label>
            <:value><.connection_status class="ml-1/2" schema={@client} /></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Owner</:label>
            <:value>
              <.link navigate={~p"/#{@account}/actors/#{@client.actor.id}"} class={[link_style()]}>
                <%= @client.actor.name %>
              </.link>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Last used sign in method</:label>
            <:value>
              <div :if={@client.actor.type != :service_account} class="flex items-center">
                <.identity_identifier account={@account} identity={@client.last_used_token.identity} />
                <.link
                  navigate={
                    ~p"/#{@account}/actors/#{@client.actor_id}?#tokens-#{@client.last_used_token_id}"
                  }
                  class={[link_style(), "text-xs"]}
                >
                  show tokens
                </.link>
              </div>
              <div :if={@client.actor.type == :service_account}>
                token
                <.link
                  navigate={
                    ~p"/#{@account}/actors/#{@client.actor_id}?#tokens-#{@client.last_used_token_id}"
                  }
                  class={[link_style()]}
                >
                  <%= @client.last_used_token.name %>
                </.link>
                <span :if={not is_nil(@client.last_used_token.deleted_at)}>
                  (deleted)
                </span>
              </div>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Version</:label>
            <:value><%= @client.last_seen_version %></:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>User agent</:label>
            <:value>
              <%= @client.last_seen_user_agent %>
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Created</:label>
            <:value>
              <.relative_datetime datetime={@client.inserted_at} />
            </:value>
          </.vertical_table_row>
          <.vertical_table_row>
            <:label>Last started</:label>
            <:value>
              <.relative_datetime datetime={@client.last_seen_at} />
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>
        Device Attributes
      </:title>

      <:help>
        Information about the device that the Client is running on.
      </:help>

      <:action :if={is_nil(@client.deleted_at) and not is_nil(@client.verified_at)}>
        <.button_with_confirmation
          id="remove_client_verification"
          style="danger"
          icon="hero-shield-exclamation"
          on_confirm="remove_client_verification"
        >
          <:dialog_title>Confirm removal of Client verification</:dialog_title>
          <:dialog_content>
            Are you sure you want to remove verification of this Client?
            It will no longer be able to access Resources using Policies that require verification.
          </:dialog_content>
          <:dialog_confirm_button>
            Remove
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Remove verification
        </.button_with_confirmation>
      </:action>
      <:action :if={is_nil(@client.deleted_at) and is_nil(@client.verified_at)}>
        <.button_with_confirmation
          id="verify_client"
          style="warning"
          confirm_style="primary"
          icon="hero-shield-check"
          on_confirm="verify_client"
        >
          <:dialog_title>Confirm verification of Client</:dialog_title>
          <:dialog_content>
            Are you sure you want to verify this Client?
          </:dialog_content>
          <:dialog_confirm_button>
            Verify
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Verify
        </.button_with_confirmation>
      </:action>

      <:content>
        <.vertical_table id="posture">
          <.vertical_table_row>
            <:label>
              <.popover>
                <:target>
                  File ID
                  <.icon name="hero-question-mark-circle" class="w-3 h-3 mb-1 text-neutral-400" />
                </:target>
                <:content>
                  Firezone-specific UUID generated and persisted to the device upon app installation.
                </:content>
              </.popover>
            </:label>
            <:value><%= @client.external_id %></:value>
          </.vertical_table_row>
          <.vertical_table_row :for={{{title, helptext}, value} <- hardware_ids(@client)}>
            <:label>
              <.popover :if={not is_nil(helptext)}>
                <:target>
                  <%= title %>
                  <.icon name="hero-question-mark-circle" class="w-3 h-3 mb-1 text-neutral-400" />
                </:target>
                <:content>
                  <%= helptext %>
                </:content>
              </.popover>
              <span :if={is_nil(helptext)}><%= title %></span>
            </:label>
            <:value><%= value %></:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Last seen remote IP</:label>
            <:value>
              <.last_seen schema={@client} />
            </:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>
              <.popover>
                <:target>
                  Verification
                  <.icon name="hero-question-mark-circle" class="w-3 h-3 mb-1 text-neutral-400" />
                </:target>
                <:content>
                  Policies can be configured to require verification in order to access a Resource.
                </:content>
              </.popover>
            </:label>
            <:value>
              <.verified_by account={@account} schema={@client} />
            </:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Operating System</:label>
            <:value>
              <.client_os client={@client} />
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Recent Connections</:title>
      <:help>
        Recent connections opened by this Client to access a Resource.
      </:help>
      <:content>
        <.live_table
          id="flows"
          rows={@flows}
          row_id={&"flows-#{&1.id}"}
          filters={@filters_by_table_id["flows"]}
          filter={@filter_form_by_table_id["flows"]}
          ordered_by={@order_by_table_id["flows"]}
          metadata={@flows_metadata}
        >
          <:col :let={flow} label="authorized">
            <.relative_datetime datetime={flow.inserted_at} />
          </:col>
          <:col :let={flow} label="remote ip" class="w-3/12">
            <%= flow.client_remote_ip %>
          </:col>
          <:col :let={flow} label="policy">
            <.link navigate={~p"/#{@account}/policies/#{flow.policy_id}"} class={[link_style()]}>
              <.policy_name policy={flow.policy} />
            </.link>
          </:col>
          <:col :let={flow} label="gateway" class="w-3/12">
            <.link navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"} class={[link_style()]}>
              <%= flow.gateway.group.name %>-<%= flow.gateway.name %>
            </.link>
            <br />
            <code class="text-xs"><%= flow.gateway_remote_ip %></code>
          </:col>
          <:col :let={flow} :if={@flow_activities_enabled?} label="activity">
            <.link navigate={~p"/#{@account}/flows/#{flow.id}"} class={[link_style()]}>
              Show
            </.link>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No activity to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@client.deleted_at)}>
      <:action>
        <.button_with_confirmation
          id="delete_client"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
        >
          <:dialog_title>Confirm deletion of client</:dialog_title>
          <:dialog_content>
            <p>
              Deleting the client doesn't remove it from the device; it will be re-created with the same
              hardware attributes upon the next sign-in, but the verification status won't carry over.
            </p>

            <p class="mt-2">
              To prevent the client owner from logging in again,
              <.link navigate={~p"/#{@account}/actors/#{@client.actor_id}"} class={link_style()}>
                disable the owning actor
              </.link>
              instead.
            </p>
          </:dialog_content>
          <:dialog_confirm_button>
            Delete Client
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete Client
        </.button_with_confirmation>
      </:action>
    </.danger_zone>
    """
  end

  defp hardware_ids(client) do
    [
      {:device_serial, client.device_serial},
      {:device_uuid, client.device_uuid},
      {:identifier_for_vendor, client.identifier_for_vendor},
      {:firebase_installation_id, client.firebase_installation_id}
    ]
    |> Enum.flat_map(fn {key, value} ->
      if is_nil(value) do
        []
      else
        [{hardware_id_title(client, key), value}]
      end
    end)
  end

  defp hardware_id_title(%{last_seen_user_agent: "Mac OS/" <> _}, :device_serial),
    do: {"Device Serial", nil}

  defp hardware_id_title(%{last_seen_user_agent: "Mac OS/" <> _}, :device_uuid),
    do: {"Device UUID", nil}

  defp hardware_id_title(%{last_seen_user_agent: "iOS/" <> _}, :identifier_for_vendor),
    do: {"App installation ID", "This value is reset if the Firezone application is reinstalled."}

  defp hardware_id_title(%{last_seen_user_agent: "Android/" <> _}, :firebase_installation_id),
    do: {"App installation ID", "This value is reset if the Firezone application is reinstalled."}

  defp hardware_id_title(_client, :device_serial),
    do: {"Device Serial", nil}

  defp hardware_id_title(_client, :device_uuid),
    do: {"Device UUID", nil}

  defp hardware_id_title(_client, :identifier_for_vendor),
    do: {"App installation ID", nil}

  defp hardware_id_title(_client, :firebase_installation_id),
    do: {"App installation ID", nil}

  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "presences:actor_clients:" <> _actor_id,
          payload: payload
        },
        socket
      ) do
    client = socket.assigns.client

    socket =
      cond do
        Map.has_key?(payload.joins, client.id) ->
          {:ok, client} =
            Clients.fetch_client_by_id(client.id, socket.assigns.subject,
              preload: [
                :actor,
                :verified_by_identity,
                :verified_by_actor,
                last_used_token: [identity: [:provider]]
              ]
            )

          assign(socket, client: %{client | online?: true})

        Map.has_key?(payload.leaves, client.id) ->
          assign(socket, client: %{client | online?: false})

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("verify_client", _params, socket) do
    {:ok, client} = Clients.verify_client(socket.assigns.client, socket.assigns.subject)

    client = %{
      client
      | online?: socket.assigns.client.online?,
        actor: socket.assigns.client.actor,
        last_used_token: socket.assigns.client.last_used_token
    }

    {:noreply, assign(socket, :client, client)}
  end

  def handle_event("remove_client_verification", _params, socket) do
    {:ok, client} =
      Clients.remove_client_verification(socket.assigns.client, socket.assigns.subject)

    client = %{
      client
      | online?: socket.assigns.client.online?,
        actor: socket.assigns.client.actor,
        last_used_token: socket.assigns.client.last_used_token
    }

    {:noreply, assign(socket, :client, client)}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _client} = Clients.delete_client(socket.assigns.client, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:info, "Client was deleted.")
      |> push_navigate(to: ~p"/#{socket.assigns.account}/clients")

    {:noreply, socket}
  end
end
