defmodule Web.Actors.Show do
  use Web, :live_view
  import Web.Actors.Components
  alias Domain.{Accounts, Auth, Tokens, Flows, Clients}
  alias Domain.Actors

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject,
             preload: [:last_seen_at, groups: [:provider]]
           ) do
      :ok = Clients.subscribe_to_clients_presence_for_actor(actor)

      socket =
        socket
        |> assign(
          page_title: "Actor #{actor.name}",
          flow_activities_enabled?: Accounts.flow_activities_enabled?(socket.assigns.account),
          actor: actor
        )
        |> assign_live_table("identities",
          query_module: Auth.Identity.Query,
          sortable_fields: [],
          limit: 10,
          callback: &handle_identities_update!/2
        )
        |> assign_live_table("tokens",
          query_module: Tokens.Token.Query,
          sortable_fields: [],
          limit: 10,
          callback: &handle_tokens_update!/2
        )
        |> assign_live_table("clients",
          query_module: Clients.Client.Query,
          sortable_fields: [],
          limit: 10,
          callback: &handle_clients_update!/2
        )
        |> assign_live_table("flows",
          query_module: Flows.Flow.Query,
          sortable_fields: [],
          limit: 10,
          callback: &handle_flows_update!/2
        )
        |> assign_live_table("groups",
          query_module: Actors.Group.Query,
          sortable_fields: [],
          hide_filters: [:provider_id],
          limit: 15,
          callback: &handle_groups_update!/2
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

  def handle_identities_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:provider, created_by_identity: [:actor]])

    with {:ok, identities, metadata} <-
           Auth.list_identities_for(socket.assigns.actor, socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         identities: identities,
         identities_metadata: metadata
       )}
    end
  end

  def handle_groups_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:provider])

    with {:ok, groups, metadata} <-
           Actors.list_groups_for(socket.assigns.actor, socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         groups: groups,
         groups_metadata: metadata
       )}
    end
  end

  def handle_tokens_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload,
        identity: [:provider],
        created_by_identity: [:actor],
        clients: []
      )

    with {:ok, tokens, metadata} <-
           Tokens.list_tokens_for(socket.assigns.actor, socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         tokens: tokens,
         tokens_metadata: metadata
       )}
    end
  end

  def handle_clients_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:online?])

    with {:ok, clients, metadata} <-
           Clients.list_clients_for(socket.assigns.actor, socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         clients: clients,
         clients_metadata: metadata
       )}
    end
  end

  def handle_flows_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload,
        gateway: [:group],
        client: [],
        policy: [:resource, :actor_group]
      )

    with {:ok, flows, metadata} <-
           Flows.list_flows_for(socket.assigns.actor, socket.assigns.subject, list_opts) do
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
      <.breadcrumb path={~p"/#{@account}/actors"}>Actors</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/actors/#{@actor}"}>
        <%= @actor.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        <%= actor_type(@actor.type) %>: <span class="font-medium"><%= @actor.name %></span>
        <span :if={@actor.id == @subject.actor.id} class="text-sm text-neutral-400">(you)</span>
        <span :if={not is_nil(@actor.deleted_at)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@actor.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/actors/#{@actor}/edit"}>
          Edit <%= actor_type(@actor.type) %>
        </.edit_button>
      </:action>
      <:action :if={is_nil(@actor.deleted_at) and not Actors.actor_disabled?(@actor)}>
        <.button
          style="warning"
          icon="hero-lock-closed"
          phx-click="disable"
          data-confirm={"Are you sure want to disable this #{actor_type(@actor.type)} and revoke all its tokens?"}
        >
          Disable <%= actor_type(@actor.type) %>
        </.button>
      </:action>
      <:action :if={is_nil(@actor.deleted_at) and Actors.actor_disabled?(@actor)}>
        <.button
          style="warning"
          icon="hero-lock-open"
          phx-click="enable"
          data-confirm={"Are you sure want to enable this #{actor_type(@actor.type)}?"}
        >
          Enable <%= actor_type(@actor.type) %>
        </.button>
      </:action>
      <:content flash={@flash}>
        <.vertical_table id="actor">
          <.vertical_table_row>
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
            <:label>Last Signed In</:label>
            <:value><.relative_datetime datetime={@actor.last_seen_at} /></:value>
          </.vertical_table_row>

          <.vertical_table_row :if={Actors.actor_synced?(@actor)}>
            <:label>Last Synced At</:label>
            <:value><.relative_datetime datetime={@actor.last_synced_at} /></:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section :if={@actor.type != :service_account}>
      <:title>Authentication Identities</:title>
      <:help>
        Each authentication identity is associated with an identity provider and is used to identify the actor upon successful authentication.
      </:help>

      <:action :if={is_nil(@actor.deleted_at)}>
        <.add_button
          :if={@actor.type != :service_account}
          navigate={~p"/#{@account}/actors/users/#{@actor}/new_identity"}
        >
          Add Identity
        </.add_button>
      </:action>

      <:content>
        <.live_table
          id="identities"
          rows={@identities}
          row_id={&"identity-#{&1.id}"}
          filters={@filters_by_table_id["identities"]}
          filter={@filter_form_by_table_id["identities"]}
          ordered_by={@order_by_table_id["identities"]}
          metadata={@identities_metadata}
        >
          <:col :let={identity} label="IDENTITY">
            <.identity_identifier account={@account} identity={identity} />
          </:col>
          <:col :let={identity} label="CREATED">
            <.created_by account={@account} schema={identity} />
          </:col>
          <:col :let={identity} label="LAST SIGNED IN">
            <.relative_datetime datetime={identity.last_seen_at} />
          </:col>
          <:action :let={identity}>
            <.button
              :if={identity_has_email?(identity)}
              icon="hero-envelope"
              phx-click="send_welcome_email"
              phx-value-id={identity.id}
            >
              Send Welcome Email
            </.button>
          </:action>
          <:action :let={identity}>
            <.delete_button
              :if={identity.created_by != :provider}
              phx-click="delete_identity"
              data-confirm="Are you sure you want to delete this identity?"
              phx-value-id={identity.id}
              class={[
                "block w-full py-2 px-4 hover:bg-neutral-100"
              ]}
            >
              Delete
            </.delete_button>
          </:action>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="w-auto pb-4">
                No authentication identities to display.
                <span :if={is_nil(@actor.deleted_at) and @actor.type == :service_account}>
                  <.link
                    class={[link_style()]}
                    navigate={~p"/#{@account}/actors/service_accounts/#{@actor}/new_identity"}
                  >
                    Create a token
                  </.link>
                  to authenticate this service account.
                </span>
                <span :if={is_nil(@actor.deleted_at) and @actor.type != :service_account}>
                  <.link
                    class={[link_style()]}
                    navigate={~p"/#{@account}/actors/users/#{@actor}/new_identity"}
                  >
                    Create an identity
                  </.link>
                  to authenticate this user.
                </span>
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.section>
      <:title>Authentication Tokens</:title>
      <:help>
        Authentication tokens are used to authenticate the actor. Revoke tokens to sign the actor out of all associated client sessions.
      </:help>

      <:action :if={is_nil(@actor.deleted_at) and @actor.type == :service_account}>
        <.add_button
          :if={@actor.type == :service_account}
          navigate={~p"/#{@account}/actors/service_accounts/#{@actor}/new_identity"}
        >
          Create Token
        </.add_button>
      </:action>

      <:action :if={is_nil(@actor.deleted_at)}>
        <.delete_button
          phx-click="revoke_all_tokens"
          data-confirm="Are you sure you want to revoke all tokens? This will immediately sign the actor out of all clients."
        >
          Revoke All
        </.delete_button>
      </:action>

      <:content>
        <.live_table
          id="tokens"
          rows={@tokens}
          row_id={&"tokens-#{&1.id}"}
          filters={@filters_by_table_id["tokens"]}
          filter={@filter_form_by_table_id["tokens"]}
          ordered_by={@order_by_table_id["tokens"]}
          metadata={@tokens_metadata}
        >
          <:col :let={token} label="TYPE" class="w-1/12">
            <%= token.type %>
          </:col>
          <:col :let={token} :if={@actor.type != :service_account} label="IDENTITY" class="w-3/12">
            <.identity_identifier account={@account} identity={token.identity} />
          </:col>
          <:col :let={token} :if={@actor.type == :service_account} label="NAME" class="w-2/12">
            <%= token.name %>
          </:col>
          <:col :let={token} label="CREATED">
            <.created_by account={@account} schema={token} />
          </:col>
          <:col :let={token} label="LAST USED (IP)">
            <p>
              <.relative_datetime datetime={token.last_seen_at} />
            </p>
            <p :if={not is_nil(token.last_seen_at)}>
              <.last_seen schema={token} />
            </p>
          </:col>
          <:col :let={token} label="EXPIRES">
            <.relative_datetime datetime={token.expires_at} />
          </:col>
          <:col :let={token} label="LAST USED BY CLIENTS">
            <.intersperse_blocks :if={token.type == :client}>
              <:separator>,&nbsp;</:separator>

              <:empty>None</:empty>

              <:item :for={client <- token.clients}>
                <.link navigate={~p"/#{@account}/clients/#{client.id}"} class={[link_style()]}>
                  <%= client.name %>
                </.link>
              </:item>
            </.intersperse_blocks>
            <span :if={token.type != :client}>N/A</span>
          </:col>
          <:action :let={token}>
            <.delete_button
              phx-click="revoke_token"
              data-confirm="Are you sure you want to revoke this token?"
              phx-value-id={token.id}
              class={[
                "block w-full py-2 px-4 hover:bg-gray-100"
              ]}
            >
              Revoke
            </.delete_button>
          </:action>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No authentication tokens to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.section>
      <:title>Clients</:title>

      <:content>
        <.live_table
          id="clients"
          rows={@clients}
          row_id={&"client-#{&1.id}"}
          filters={@filters_by_table_id["clients"]}
          filter={@filter_form_by_table_id["clients"]}
          ordered_by={@order_by_table_id["clients"]}
          metadata={@clients_metadata}
        >
          <:col :let={client} label="NAME">
            <.link navigate={~p"/#{@account}/clients/#{client.id}"} class={[link_style()]}>
              <%= client.name %>
            </.link>
          </:col>
          <:col :let={client} label="STATUS">
            <.connection_status schema={client} />
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No clients to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.section>
      <:title>Activity</:title>
      <:help>
        Attempts to access resources by this actor.
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
          <:col :let={flow} label="AUTHORIZED AT">
            <.relative_datetime datetime={flow.inserted_at} />
          </:col>
          <:col :let={flow} label="EXPIRES AT">
            <.relative_datetime datetime={flow.expires_at} />
          </:col>
          <:col :let={flow} label="POLICY">
            <.link navigate={~p"/#{@account}/policies/#{flow.policy_id}"} class={[link_style()]}>
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
            <.link navigate={~p"/#{@account}/gateways/#{flow.gateway_id}"} class={[link_style()]}>
              <%= flow.gateway.group.name %>-<%= flow.gateway.name %>
            </.link>
            (<%= flow.gateway_remote_ip %>)
          </:col>
          <:col :let={flow} :if={@flow_activities_enabled?} label="ACTIVITY">
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

    <.section>
      <:title>Groups</:title>

      <:action>
        <.edit_button navigate={~p"/#{@account}/actors/#{@actor}/groups"}>
          Edit Groups
        </.edit_button>
      </:action>

      <:content>
        <.live_table
          id="groups"
          rows={@groups}
          row_id={&"group-#{&1.id}"}
          filters={@filters_by_table_id["groups"]}
          filter={@filter_form_by_table_id["groups"]}
          ordered_by={@order_by_table_id["groups"]}
          metadata={@groups_metadata}
        >
          <:col :let={group} label="NAME">
            <.link navigate={~p"/#{@account}/groups/#{group.id}"} class={[link_style()]}>
              <%= group.name %>
            </.link>
          </:col>
          <:empty>
            <div class="text-center text-neutral-500 p-4">No Groups to display.</div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@actor.deleted_at)}>
      <:action :if={not Actors.actor_synced?(@actor) or @identities == []}>
        <.delete_button
          phx-click="delete"
          data-confirm={"Are you sure want to delete this #{actor_type(@actor.type)} along with all associated identities?"}
        >
          Delete <%= actor_type(@actor.type) %>
        </.delete_button>
      </:action>
    </.danger_zone>
    """
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:actor_clients:" <> _actor_id},
        socket
      ) do
    {:noreply, reload_live_table!(socket, "clients")}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

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
      actor = %{actor | groups: socket.assigns.actor.groups}

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
    actor = %{actor | groups: socket.assigns.actor.groups}

    socket =
      socket
      |> put_flash(:info, "Actor was enabled.")
      |> assign(actor: actor)

    {:noreply, socket}
  end

  def handle_event("delete_identity", %{"id" => id}, socket) do
    {:ok, identity} = Auth.fetch_identity_by_id(id, socket.assigns.subject)
    {:ok, _identity} = Auth.delete_identity(identity, socket.assigns.subject)

    socket =
      socket
      |> reload_live_table!("identities")
      |> put_flash(:info, "Identity was deleted.")

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

  def handle_event("revoke_all_tokens", _params, socket) do
    {:ok, deleted_tokens} = Tokens.delete_tokens_for(socket.assigns.actor, socket.assigns.subject)

    socket =
      socket
      |> reload_live_table!("tokens")
      |> put_flash(:info, "#{length(deleted_tokens)} token(s) were revoked.")

    {:noreply, socket}
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    {:ok, token} = Tokens.fetch_token_by_id(id, socket.assigns.subject)
    {:ok, _token} = Tokens.delete_token(token, socket.assigns.subject)

    socket =
      socket
      |> reload_live_table!("tokens")
      |> put_flash(:info, "Token was revoked.")

    {:noreply, socket}
  end
end
