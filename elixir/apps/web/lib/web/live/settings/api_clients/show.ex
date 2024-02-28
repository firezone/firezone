defmodule Web.Settings.ApiClients.Show do
  use Web, :live_view
  alias Domain.{Actors, Tokens}

  def mount(%{"id" => id}, _session, socket) do
    unless Domain.Config.global_feature_enabled?(:api_client_ui),
      do: raise(Web.LiveErrors.NotFoundError)

    with {:ok, actor} <-
           Actors.fetch_actor_by_id(id, socket.assigns.subject, preload: []),
         {:ok, tokens} <-
           Tokens.list_tokens_for(actor, socket.assigns.subject, preload: :created_by_identity) do
      socket =
        assign(
          socket,
          actor: actor,
          tokens: tokens,
          page_title: "API Client #{actor.name}"
        )

      {:ok, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients"}>API Clients</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/settings/api_clients/#{@actor}"}>
        <%= @actor.name %>
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        API Client: <span class="font-medium"><%= @actor.name %></span>
        <span :if={Actors.actor_deleted?(@actor)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@actor.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/settings/api_clients/#{@actor}/edit"}>
          Edit API Client
        </.edit_button>
      </:action>
      <:action :if={Actors.actor_active?(@actor)}>
        <.button
          style="warning"
          icon="hero-lock-closed"
          phx-click="disable"
          data-confirm="Are you sure want to disable this API Client and revoke all its tokens?"
        >
          Disable API Client
        </.button>
      </:action>
      <:action :if={is_nil(@actor.deleted_at) and Actors.actor_disabled?(@actor)}>
        <.button
          style="warning"
          icon="hero-lock-open"
          phx-click="enable"
          data-confirm="Are you sure want to enable this API Client?"
        >
          Enable API Client
        </.button>
      </:action>
      <:content flash={@flash}>
        <.vertical_table id="api-client">
          <.vertical_table_row>
            <:label>Name</:label>
            <:value><%= @actor.name %></:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Created</:label>
            <:value>
              <%= Cldr.DateTime.Formatter.date(@actor.inserted_at, 1, "en", Web.CLDR, []) %>
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>API Tokens</:title>

      <:action :if={Actors.actor_active?(@actor) and @actor.type == :api_client}>
        <.add_button
          :if={@actor.type == :api_client}
          navigate={~p"/#{@account}/settings/api_clients/#{@actor}/new_token"}
        >
          Create Token
        </.add_button>
      </:action>

      <:action :if={Actors.actor_active?(@actor)}>
        <.delete_button
          phx-click="revoke_all_tokens"
          data-confirm="Are you sure you want to revoke all tokens for this API client?"
        >
          Revoke All
        </.delete_button>
      </:action>

      <:content>
        <.table id="tokens" rows={@tokens} row_id={&"api-client-token-#{&1.id}"}>
          <:col :let={token} label="name" sortable="false">
            <%= token.name %>
          </:col>
          <:col :let={token} label="expires at" sortable="false">
            <%= Cldr.DateTime.Formatter.date(token.expires_at, 1, "en", Web.CLDR, []) %>
          </:col>
          <:col :let={token} label="created by" sortable="false">
            <%= token.created_by_identity.provider_identifier %>
          </:col>
          <:col :let={token} label="last seen at" sortable="false">
            <.relative_datetime datetime={token.last_seen_at} />
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
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="w-auto pb-4">
                No API tokens to display.
              </div>
            </div>
          </:empty>
        </.table>
      </:content>
    </.section>

    <.danger_zone :if={is_nil(@actor.deleted_at)}>
      <:action>
        <.delete_button
          phx-click="delete"
          data-confirm="Are you sure want to delete this API Client along with all associated tokens?"
        >
          Delete API Client
        </.delete_button>
      </:action>
    </.danger_zone>
    """
  end

  def handle_event("disable", _params, socket) do
    with {:ok, actor} <- Actors.disable_actor(socket.assigns.actor, socket.assigns.subject),
         {:ok, tokens} <-
           Tokens.list_tokens_for(actor, socket.assigns.subject, preload: :created_by_identity) do
      socket =
        socket
        |> put_flash(:info, "API Client was disabled.")
        |> assign(actor: actor, tokens: tokens)

      {:noreply, socket}
    end
  end

  def handle_event("enable", _params, socket) do
    {:ok, actor} = Actors.enable_actor(socket.assigns.actor, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:info, "API Client was enabled.")
      |> assign(actor: actor)

    {:noreply, socket}
  end

  def handle_event("revoke_all_tokens", _params, socket) do
    {:ok, deleted_tokens} = Tokens.delete_tokens_for(socket.assigns.actor, socket.assigns.subject)

    {:ok, tokens} =
      Tokens.list_tokens_for(socket.assigns.actor, socket.assigns.subject,
        preload: :created_by_identity
      )

    socket =
      socket
      |> put_flash(:info, "#{length(deleted_tokens)} token(s) were revoked.")
      |> assign(tokens: tokens)

    {:noreply, socket}
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    {:ok, token} = Tokens.fetch_token_by_id(id, socket.assigns.subject)
    {:ok, _token} = Tokens.delete_token(token, socket.assigns.subject)

    {:ok, tokens} =
      Tokens.list_tokens_for(socket.assigns.actor, socket.assigns.subject,
        preload: :created_by_identity
      )

    socket =
      socket
      |> put_flash(:info, "Token was revoked.")
      |> assign(tokens: tokens)

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    with {:ok, _actor} <- Actors.delete_actor(socket.assigns.actor, socket.assigns.subject) do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients")}
    end
  end
end
