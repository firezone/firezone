defmodule Web.Settings.ApiClients.Show do
  use Web, :live_view
  alias Domain.{Actors, Tokens}

  def mount(%{"id" => id}, _session, socket) do
    if Domain.Accounts.rest_api_enabled?(socket.assigns.account) do
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
            callback: &handle_tokens_update!/2
          )

        {:ok, socket}
      end
    else
      {:ok, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients/beta")}
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
        {@actor.name}
      </.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        API Client: <span class="font-medium">{@actor.name}</span>
        <span :if={Actors.actor_deleted?(@actor)} class="text-red-600">(deleted)</span>
      </:title>
      <:action :if={is_nil(@actor.deleted_at)}>
        <.edit_button navigate={~p"/#{@account}/settings/api_clients/#{@actor}/edit"}>
          Edit API Client
        </.edit_button>
      </:action>
      <:action :if={Actors.actor_active?(@actor)}>
        <.button_with_confirmation
          id="disable"
          style="warning"
          icon="hero-lock-closed"
          on_confirm="disable"
        >
          <:dialog_title>Confirm disabling the API Client</:dialog_title>
          <:dialog_content>
            Are you sure want to disable this API Client and revoke all its tokens?
          </:dialog_content>
          <:dialog_confirm_button>
            Disable
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Disable API Client
        </.button_with_confirmation>
      </:action>
      <:action :if={is_nil(@actor.deleted_at) and Actors.actor_disabled?(@actor)}>
        <.button_with_confirmation
          id="enable"
          style="warning"
          confirm_style="primary"
          icon="hero-lock-open"
          on_confirm="enable"
        >
          <:dialog_title>Confirm enabling the API Client</:dialog_title>
          <:dialog_content>
            Are you sure want to enable this API Client?
          </:dialog_content>
          <:dialog_confirm_button>
            Enable
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Enable API Client
        </.button_with_confirmation>
      </:action>
      <:content flash={@flash}>
        <.vertical_table id="api-client">
          <.vertical_table_row>
            <:label>Name</:label>
            <:value>{@actor.name}</:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Created</:label>
            <:value>
              {Cldr.DateTime.Formatter.date(@actor.inserted_at, 1, "en", Web.CLDR, [])}
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
        <.button_with_confirmation
          id="revoke_all_tokens"
          style="danger"
          icon="hero-trash"
          on_confirm="revoke_all_tokens"
        >
          <:dialog_title>Confirm revocation of all API Client tokens</:dialog_title>
          <:dialog_content>
            Are you sure you want to revoke all Tokens for this API client?
          </:dialog_content>
          <:dialog_confirm_button>
            Revoke All
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Revoke All
        </.button_with_confirmation>
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
            {token.name}
          </:col>
          <:col :let={token} label="expires at">
            {Cldr.DateTime.Formatter.date(token.expires_at, 1, "en", Web.CLDR, [])}
          </:col>
          <:col :let={token} label="created by">
            <.link
              class={[link_style()]}
              navigate={~p"/#{@account}/actors/#{token.created_by_actor_id}"}
            >
              {get_identity_email(token.created_by_identity)}
            </.link>
          </:col>
          <:col :let={token} label="last used">
            <.relative_datetime datetime={token.last_seen_at} />
          </:col>
          <:col :let={token} label="last used IP">
            {token.last_seen_remote_ip}
          </:col>
          <:action :let={token}>
            <.button_with_confirmation
              id={"revoke_token_#{token.id}"}
              style="danger"
              icon="hero-trash-solid"
              on_confirm="revoke_token"
              on_confirm_id={token.id}
              size="xs"
            >
              <:dialog_title>Confirm revocation of API Token</:dialog_title>
              <:dialog_content>
                Are you sure you want to revoke this token?
              </:dialog_content>
              <:dialog_confirm_button>
                Revoke
              </:dialog_confirm_button>
              <:dialog_cancel_button>
                Cancel
              </:dialog_cancel_button>
              Revoke
            </.button_with_confirmation>
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
        <.button_with_confirmation
          id="delete_api_client"
          style="danger"
          icon="hero-trash-solid"
          on_confirm="delete"
        >
          <:dialog_title>Confirm deletion of API Client</:dialog_title>
          <:dialog_content>
            Are you sure want to delete this API Client along with all associated tokens?
          </:dialog_content>
          <:dialog_confirm_button>
            Delete API Client
          </:dialog_confirm_button>
          <:dialog_cancel_button>
            Cancel
          </:dialog_cancel_button>
          Delete API Client
        </.button_with_confirmation>
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
