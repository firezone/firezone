defmodule PortalWeb.Settings.ApiClients.Show do
  use PortalWeb, :live_view
  alias __MODULE__.Database
  import Ecto.Changeset

  def mount(%{"id" => id}, _session, socket) do
    if Portal.Account.rest_api_enabled?(socket.assigns.account) do
      actor = Database.get_api_client!(id, socket.assigns.subject)

      socket =
        socket
        |> assign(
          actor: actor,
          page_title: "API Client #{actor.name}"
        )
        |> assign_live_table("tokens",
          query_module: Database,
          sortable_fields: [],
          callback: &handle_tokens_update!/2
        )

      {:ok, socket}
    else
      {:ok, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients/beta")}
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_tokens_update!(socket, list_opts) do
    case Database.list_tokens_for(socket.assigns.actor, socket.assigns.subject, list_opts) do
      {:ok, tokens, metadata} ->
        {:ok,
         assign(socket,
           tokens: tokens,
           tokens_metadata: metadata
         )}

      {:error, :unauthorized} ->
        {:ok, assign(socket, tokens: [], tokens_metadata: %{})}
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
      </:title>
      <:action>
        <.edit_button navigate={~p"/#{@account}/settings/api_clients/#{@actor}/edit"}>
          Edit API Client
        </.edit_button>
      </:action>
      <:action :if={is_nil(@actor.disabled_at)}>
        <.button_with_confirmation
          id="disable"
          style="warning"
          icon="hero-lock-closed"
          on_confirm="disable"
        >
          <:dialog_title>Confirm disabling the API Client</:dialog_title>
          <:dialog_content>
            Are you sure want to disable this API Client? It will no longer be able to authenticate.
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
      <:action :if={@actor.disabled_at}>
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
      <:content>
        <.vertical_table id="api-client">
          <.vertical_table_row>
            <:label>Name</:label>
            <:value>{@actor.name}</:value>
          </.vertical_table_row>

          <.vertical_table_row>
            <:label>Created</:label>
            <:value>
              {PortalWeb.Format.short_date(@actor.inserted_at)}
            </:value>
          </.vertical_table_row>
        </.vertical_table>
      </:content>
    </.section>

    <.section>
      <:title>API Tokens</:title>

      <:action :if={is_nil(@actor.disabled_at)}>
        <.add_button navigate={~p"/#{@account}/settings/api_clients/#{@actor}/new_token"}>
          Create Token
        </.add_button>
      </:action>

      <:action :if={is_nil(@actor.disabled_at)}>
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
            {PortalWeb.Format.short_date(token.expires_at)}
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

    <.danger_zone>
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
    changeset = disable_actor_changeset(socket.assigns.actor)

    with {:ok, actor} <- Database.update_actor(changeset, socket.assigns.subject) do
      socket =
        socket
        |> put_flash(:success, "API Client was disabled.")
        |> assign(actor: actor)
        |> reload_live_table!("tokens")

      {:noreply, socket}
    end
  end

  def handle_event("enable", _params, socket) do
    changeset = enable_actor_changeset(socket.assigns.actor)
    {:ok, actor} = Database.update_actor(changeset, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:success, "API Client was enabled.")
      |> assign(actor: actor)
      |> reload_live_table!("tokens")

    {:noreply, socket}
  end

  def handle_event("revoke_all_tokens", _params, socket) do
    {:ok, deleted_tokens_count} =
      Database.delete_all_tokens_for_actor(socket.assigns.actor, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:success, "#{deleted_tokens_count} token(s) were revoked.")
      |> reload_live_table!("tokens")

    {:noreply, socket}
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    {:ok, _token} = Database.delete_token(id, socket.assigns.subject)

    socket =
      socket
      |> put_flash(:success, "Token was revoked.")
      |> reload_live_table!("tokens")

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    with {:ok, _actor} <- Database.delete_actor(socket.assigns.actor, socket.assigns.subject) do
      {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients")}
    end
  end

  defp disable_actor_changeset(actor) do
    actor
    |> change()
    |> put_change(:disabled_at, DateTime.utc_now())
  end

  defp enable_actor_changeset(actor) do
    actor
    |> change()
    |> put_change(:disabled_at, nil)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_api_client!(id, subject) do
      from(a in Portal.Actor,
        where: a.id == ^id,
        where: a.type == :api_client
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def update_actor(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def list_tokens_for(actor, subject, opts \\ []) do
      from(t in Portal.APIToken,
        as: :tokens,
        where: t.actor_id == ^actor.id,
        order_by: [desc: t.inserted_at, desc: t.id]
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def delete_all_tokens_for_actor(actor, subject) do
      query = from(t in Portal.APIToken, where: t.actor_id == ^actor.id)
      {count, _} = query |> Safe.scoped(subject) |> Safe.delete_all()
      {:ok, count}
    end

    def delete_token(token_id, subject) do
      result =
        from(t in Portal.APIToken,
          where: t.id == ^token_id,
          where: t.expires_at > ^DateTime.utc_now() or is_nil(t.expires_at)
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.one(fallback_to_primary: true)

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        token -> Safe.scoped(token, subject) |> Safe.delete()
      end
    end

    def delete_actor(actor, subject) do
      actor
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def cursor_fields do
      [
        {:tokens, :desc, :inserted_at},
        {:tokens, :desc, :id}
      ]
    end
  end
end
