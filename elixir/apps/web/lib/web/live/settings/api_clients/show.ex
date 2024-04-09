defmodule Web.Settings.ApiClients.Show do
  use Web, :live_view
  alias Domain.{Actors, Tokens}

  def mount(%{"id" => id}, _session, socket) do
    unless Domain.Config.global_feature_enabled?(:rest_api),
      do: raise(Web.LiveErrors.NotFoundError)

    with {:ok, actor} <- Actors.fetch_actor_by_id(id, socket.assigns.subject, preload: []) do
      socket =
        socket
        |> assign(
          actor: actor,
          page_title: "API Client #{actor.name}"
        )
        |> assign_live_table("tokens",
          query_module: Tokens.Token.Query,
          sortable_fields: [],
          limit: 10,
          callback: &handle_tokens_update!/2
        )

      {:ok, socket}
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_tokens_update!(socket, list_opts) do
    list_opts =
      Keyword.put(list_opts, :preload, created_by_identity: [:actor])

    with {:ok, tokens, metadata} <-
           Tokens.list_tokens_for(socket.assigns.actor, socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         tokens: tokens,
         tokens_metadata: metadata
       )}
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
        <.live_table
          id="tokens"
          rows={@tokens}
          row_id={&"api-client-token-#{&1.id}"}
          filters={@filters_by_table_id["tokens"]}
          filter={@filter_form_by_table_id["tokens"]}
          ordered_by={@order_by_table_id["tokens"]}
          metadata={@tokens_metadata}
        >
          <:col :let={token} label="name">
            <%= token.name %>
          </:col>
          <:col :let={token} label="expires at">
            <%= Cldr.DateTime.Formatter.date(token.expires_at, 1, "en", Web.CLDR, []) %>
          </:col>
          <:col :let={token} label="created by">
            <%= token.created_by_identity.provider_identifier %>
          </:col>
          <:col :let={token} label="last used">
            <.relative_datetime datetime={token.last_seen_at} />
          </:col>
          <:col :let={token} label="last used IP">
            <%= token.last_seen_remote_ip %>
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
        </.live_table>
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
    with {:ok, actor} <- Actors.disable_actor(socket.assigns.actor, socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:info, "API Client was disabled.")
        |> assign(actor: actor)
        |> reload_live_table!("tokens")

      {:noreply, socket}
    end
  end

  def handle_event("enable", _params, socket) do
    {:ok, actor} = Actors.enable_actor(socket.assigns.actor, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:info, "API Client was enabled.")
      |> assign(actor: actor)
      |> reload_live_table!("tokens")

    {:noreply, socket}
  end

  def handle_event("revoke_all_tokens", _params, socket) do
    {:ok, deleted_tokens} = Tokens.delete_tokens_for(socket.assigns.actor, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:info, "#{length(deleted_tokens)} token(s) were revoked.")
      |> reload_live_table!("tokens")

    {:noreply, socket}
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    {:ok, token} = Tokens.fetch_token_by_id(id, socket.assigns.subject)
    {:ok, _token} = Tokens.delete_token(token, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:info, "Token was revoked.")
      |> reload_live_table!("tokens")

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    with {:ok, _actor} <- Actors.delete_actor(socket.assigns.actor, socket.assigns.subject) do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients")}
    end
  end
end
