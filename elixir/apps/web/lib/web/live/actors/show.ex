defmodule Web.Actors.Show do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.{Auth, Flows, Clients}
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject,
             preload: [
               identities: [:provider, created_by_identity: [:actor]],
               groups: [:provider],
               clients: []
             ]
           ),
         {:ok, flows} <-
           Flows.list_flows_for(actor, socket.assigns.subject,
             preload: [gateway: [:group], client: [], policy: [:resource, :actor_group]]
           ) do
      actor = %{actor | clients: Clients.preload_online_statuses(actor.clients)}
      :ok = Clients.subscribe_for_clients_presence_for_actor(actor)

      {:ok,
       assign(socket,
         actor: actor,
         flows: flows,
         page_title: actor.name,
         flow_activities_enabled?: Domain.Config.flow_activities_enabled?()
       )}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor}"}>
        <%= @actor.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        <%= actor_type(@actor.type) %>: <span class="font-bold"><%= @actor.name %></span>
        <span :if={@actor.id == @subject.actor.id} class="text-neutral-400">(you)</span>
        <span :if={not is_nil(@actor.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@actor.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/actors/#{@actor}/edit"}>
          Edit <%= actor_type(@actor.type) %>
        </.edit_button>
      </:action>
      <:content flash={@flash}>
        <.vertical_table id="actor">
          <.vertical_table_row label_class="w-1/5">
            <:label>Name</:label>
            <:value><%= @actor.name %>
              <.actor_status actor={@actor} /></:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Role</:label>
            <:value>
              <%= actor_role(@actor.type) %>
            </:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Groups</:label>
            <:value>
              <div class="flex flex-wrap gap-y-2">
                <span :if={Enum.empty?(@actor.groups)}>none</span>
                <span :for={group <- @actor.groups}>
                  <.group account={@account} group={group} />
                </span>
              </div>
            </:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Last Signed In</:label>
            <:value><.relative_datetime datetime={last_seen_at(@actor.identities)} /></:value>
          </.vertical_table_row>

          <.vertical_table_row :if={Actors.actor_synced?(@actor)}>
            <:label>Last Synced At</:label>
            <:value><.relative_datetime datetime={@actor.last_synced_at} /></:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>Authentication Identities</:title>
      <:action :if={is_nil(@actor.deleted_at)}>
        <.add_button
          :if={@actor.type == :service_account}
          navigate={~p"/#{@account}/actors/service_accounts/#{@actor}/new_identity"}
        >
          Create Token
        </.add_button>
      </:action>
      <:action :if={is_nil(@actor.deleted_at)}>
        <.add_button
          :if={@actor.type != :service_account}
          navigate={~p"/#{@account}/actors/users/#{@actor}/new_identity"}
        >
          Add Identity
        </.add_button>
      </:action>

      <:content>
        <.table id="actors" rows={@actor.identities} row_id={&"identity-#{&1.id}"}>
          <:col :let={identity} label="IDENTITY" sortable="false">
            <.identity_identifier account={@account} identity={identity} />
          </:col>

          <:col :let={identity} label="CREATED" sortable="false">
            <.created_by account={@account} schema={identity} />
          </:col>
          <:col :let={identity} label="LAST SIGNED IN" sortable="false">
            <.relative_datetime datetime={identity.last_seen_at} />
          </:col>
          <:action :let={identity}>
            <button
              :if={identity_has_email?(identity)}
              phx-click="send_welcome_email"
              phx-value-id={identity.id}
              class={[
                "block w-full py-2 px-4 hover:bg-neutral-100"
              ]}
            >
              Send Welcome Email
            </button>
          </:action>
          <:action :let={identity}>
            <button
              :if={identity.created_by != :provider}
              phx-click="delete_identity"
              data-confirm="Are you sure want to delete this identity?"
              phx-value-id={identity.id}
              class={[
                "block w-full py-2 px-4 hover:bg-neutral-100"
              ]}
            >
              Delete
            </button>
          </:action>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="w-auto">
                <div class="pb-4">
                  No authentication identities to display
                </div>
                <.add_button
                  :if={is_nil(@actor.deleted_at) and @actor.type == :service_account}
                  navigate={~p"/#{@account}/actors/service_accounts/#{@actor}/new_identity"}
                >
                  Create Token
                </.add_button>
                <.add_button
                  :if={is_nil(@actor.deleted_at) and @actor.type != :service_account}
                  navigate={~p"/#{@account}/actors/users/#{@actor}/new_identity"}
                >
                  Create Identity
                </.add_button>
              </div>
            </div>
          </:empty>
        </.table>
      </:content>
    </.section>

    <.section>
      <:title>Clients</:title>

      <:content>
        <.table id="clients" rows={@actor.clients} row_id={&"client-#{&1.id}"}>
          <:col :let={client} label="NAME">
            <.link
              navigate={~p"/#{@account}/clients/#{client.id}"}
              class={["font-medium", link_style()]}
            >
              <%= client.name %>
            </.link>
          </:col>
          <:col :let={client} label="STATUS">
            <.connection_status schema={client} />
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No clients to display</div>
          </:empty>
        </.table>
      </:content>
    </.section>

    <.section>
      <:title>Authorizations</:title>
      <:content>
        <.table id="flows" rows={@flows} row_id={&"flows-#{&1.id}"}>
          <:col :let={flow} label="AUTHORIZED AT">
            <.relative_datetime datetime={flow.inserted_at} />
          </:col>
          <:col :let={flow} label="EXPIRES AT">
            <.relative_datetime datetime={flow.expires_at} />
          </:col>
          <:col :let={flow} label="POLICY">
            <.link
              navigate={~p"/#{@account}/policies/#{flow.policy_id}"}
              class={["font-medium", link_style()]}
            >
              <Web.Policies.Components.policy_name policy={flow.policy} />
            </.link>
          </:col>
          <:col :let={flow} label="CLIENT (IP)">
            <.link navigate={~p"/#{@account}/clients/#{flow.client_id}"} class={link_style()}>
              <%= flow.client.name %>
            </.link>
            (<%= flow.client_remote_ip %>)
          </:col>
          <:col :let={flow} label="GATEWAY (IP)">
            <.link
              navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"}
              class={["font-medium", link_style()]}
            >
              <%= flow.gateway.group.name %>-<%= flow.gateway.name %>
            </.link>
            (<%= flow.gateway_remote_ip %>)
          </:col>
          <:col :let={flow} :if={@flow_activities_enabled?} label="ACTIVITY">
            <.link navigate={~p"/#{@account}/flows/#{flow.id}"} class={["font-medium", link_style()]}>
              Show
            </.link>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No authorizations to display</div>
          </:empty>
        </.table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@actor.deleted_at)}>
      <:action>
        <.button
          :if={not Actors.actor_disabled?(@actor)}
          style="warning"
          icon="hero-lock-closed"
          phx-click="disable"
          data-confirm={"Are you sure want to disable this #{actor_type(@actor.type)}?"}
        >
          Disable <%= actor_type(@actor.type) %>
        </.button>
      </:action>
      <:action>
        <.button
          :if={Actors.actor_disabled?(@actor)}
          style="warning"
          icon="hero-lock-open"
          phx-click="enable"
          data-confirm={"Are you sure want to enable this #{actor_type(@actor.type)}?"}
        >
          Enable <%= actor_type(@actor.type) %>
        </.button>
      </:action>
      <:action>
        <.delete_button
          :if={not Actors.actor_synced?(@actor)}
          phx-click="delete"
          data-confirm={"Are you sure want to delete this #{actor_type(@actor.type)} and all associated identities?"}
        >
          Delete <%= actor_type(@actor.type) %>
        </.delete_button>
      </:action>
      <:content></:content>
    </.danger_zone>
    """
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "actor_clients:" <> _account_id}, socket) do
    {:ok, actor} =
      Actors.fetch_actor_by_id(socket.assigns.actor.id, socket.assigns.subject,
        preload: [clients: []]
      )

    actor = %{socket.assigns.actor | clients: Clients.preload_online_statuses(actor.clients)}

    {:noreply, assign(socket, actor: actor)}
  end

  def handle_event("delete", _params, socket) do
    with {:ok, _actor} <- Actors.delete_actor(socket.assigns.actor, socket.assigns.subject) do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/actors")}
    else
      {:error, :cant_delete_the_last_admin} ->
        {:noreply, put_flash(socket, :error, "You can't delete the last admin of an account.")}
    end
  end

  def handle_event("disable", _params, socket) do
    with {:ok, actor} <- Actors.disable_actor(socket.assigns.actor, socket.assigns.subject) do
      actor = %{
        actor
        | identities: socket.assigns.actor.identities,
          groups: socket.assigns.actor.groups,
          clients: socket.assigns.actor.clients
      }

      socket =
        socket
        |> put_flash(:info, "Actor was disabled.")
        |> assign(actor: actor)

      {:noreply, socket}
    else
      {:error, :cant_disable_the_last_admin} ->
        {:noreply, put_flash(socket, :error, "You can't disable the last admin of an account.")}
    end
  end

  def handle_event("enable", _params, socket) do
    {:ok, actor} = Actors.enable_actor(socket.assigns.actor, socket.assigns.subject)

    actor = %{
      actor
      | identities: socket.assigns.actor.identities,
        groups: socket.assigns.actor.groups,
        clients: socket.assigns.actor.clients
    }

    socket =
      socket
      |> put_flash(:info, "Actor was enabled.")
      |> assign(actor: actor)

    {:noreply, socket}
  end

  def handle_event("delete_identity", %{"id" => id}, socket) do
    {:ok, identity} = Auth.fetch_identity_by_id(id, socket.assigns.subject)
    {:ok, _identity} = Auth.delete_identity(identity, socket.assigns.subject)

    {:ok, actor} =
      Actors.fetch_actor_by_id(socket.assigns.actor.id, socket.assigns.subject,
        preload: [
          identities: [:provider, created_by_identity: [:actor]]
        ]
      )

    actor = %{
      actor
      | groups: socket.assigns.actor.groups,
        clients: socket.assigns.actor.clients
    }

    socket =
      socket
      |> put_flash(:info, "Identity was deleted.")
      |> assign(actor: actor)

    {:noreply, socket}
  end

  def handle_event("send_welcome_email", %{"id" => id}, socket) do
    {:ok, identity} = Auth.fetch_identity_by_id(id, socket.assigns.subject)

    {:ok, _} =
      Web.Mailer.AuthEmail.new_user_email(
        socket.assigns.account,
        identity,
        socket.assigns.subject
      )
      |> Web.Mailer.deliver()

    socket =
      socket
      |> put_flash(:info, "Welcome email sent to #{identity.provider_identifier}")

    {:noreply, socket}
  end

  defp last_seen_at(identities) do
    identities
    |> Enum.reject(&is_nil(&1.last_seen_at))
    |> Enum.max_by(& &1.last_seen_at, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      identity -> identity.last_seen_at
    end
  end
end
