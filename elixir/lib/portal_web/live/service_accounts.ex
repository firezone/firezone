defmodule PortalWeb.ServiceAccounts do
  use PortalWeb, :live_view

  alias __MODULE__.Database
  import PortalWeb.Actors.Components

  alias Portal.Actor
  alias Portal.Authentication
  alias Portal.Presence
  alias Portal.ClientToken

  import Ecto.Changeset

  require Logger

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Service Accounts")
      |> assign(
        selected_actor: nil,
        portal_sessions_subscribed_actor_id: nil,
        client_tokens_subscribed_actor_id: nil
      )
      |> assign(base_actor_assigns())
      |> assign_live_table("actors",
        query_module: Database,
        sortable_fields: [
          {:actors, :name},
          {:actors, :updated_at}
        ],
        callback: &handle_actors_update!/2
      )

    {:ok, socket}
  end

  # New Service Account Panel
  def handle_params(params, uri, %{assigns: %{live_action: :new}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    changeset = changeset(%Actor{type: :service_account}, %{})

    {:noreply,
     socket
     |> assign(selected_actor: nil)
     |> assign(base_actor_assigns())
     |> merge_state(:actor_panel, creating_actor: true, new_actor_type: :service_account)
     |> assign(actor_form: actor_form_state(to_form(changeset)))
     |> assign(actor_token: actor_token_state(token_expiration: default_token_expiration()))}
  end

  # Show Panel
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)

    if selected_actor_matches?(socket, id) do
      actor = socket.assigns.selected_actor

      socket =
        socket
        |> merge_state(:actor_panel,
          view: :detail,
          active_tab: Map.get(params, "tab", "tokens"),
          confirm_disable_actor: false,
          confirm_delete_actor: false,
          confirm_delete_identity_id: nil,
          confirm_delete_token_id: nil,
          confirm_delete_session_id: nil
        )
        |> subscribe_client_tokens(actor)

      {:noreply, socket}
    else
      {:noreply, handle_actor_show(socket, id, params)}
    end
  end

  # Edit Panel
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    with {:ok, actor} <- Database.get_actor(id, socket.assigns.subject) do
      socket = handle_live_tables_params(socket, params, uri)
      changeset = changeset(actor, %{})

      {:noreply,
       socket
       |> assign(selected_actor: actor)
       |> assign(base_actor_assigns())
       |> assign(
         actor_panel: actor_panel_state(view: :edit, is_last_admin: false),
         actor_form: actor_form_state(to_form(changeset)),
         actor_related: actor_related_state(),
         actor_group_membership: actor_group_membership_state()
       )}
    else
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Service account not found")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/service_accounts")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to view this service account")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/service_accounts")}
    end
  end

  # Default handler — list view
  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    socket =
      socket
      |> assign(selected_actor: nil)
      |> assign(base_actor_assigns())
      |> unsubscribe_client_tokens()

    {:noreply, socket}
  end

  def handle_event(event, params, socket)
      when event in ["paginate", "order_by", "filter", "table_row_click", "change_limit"],
      do: handle_live_table_event(event, params, socket)

  def handle_event("close_panel", _params, %{assigns: %{actor_panel: %{creating_actor: true}}} = socket) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/service_accounts?#{params}")}
  end

  def handle_event("close_panel", _params, socket) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/service_accounts?#{params}")}
  end

  def handle_event("handle_keydown", _params, %{assigns: %{live_action: :edit}} = socket)
      when not is_nil(socket.assigns.selected_actor) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/service_accounts/#{socket.assigns.selected_actor.id}"
     )}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_actor) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/service_accounts?#{params}")}
  end

  def handle_event(
        "handle_keydown",
        _params,
        %{assigns: %{actor_panel: %{creating_actor: true}}} = socket
      ) do
    params = Map.drop(socket.assigns.query_params, ["tab"])
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/service_accounts?#{params}")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_new_actor_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/service_accounts/new")}
  end

  def handle_event("open_actor_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/#{socket.assigns.account}/service_accounts/#{socket.assigns.selected_actor.id}/edit"
     )}
  end

  def handle_event("cancel_actor_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/service_accounts/#{socket.assigns.selected_actor.id}"
     )}
  end

  def handle_event("validate", %{"actor" => attrs} = params, socket) do
    actor = socket.assigns.selected_actor || socket.assigns.actor_form.form.data

    changeset =
      actor
      |> changeset(attrs)
      |> Map.put(:action, :validate)

    token_expiration =
      Map.get(params, "token_expiration", socket.assigns.actor_token.token_expiration || "")

    {:noreply,
     socket
     |> assign(actor_form: actor_form_state(to_form(changeset)))
     |> merge_state(:actor_token, token_expiration: token_expiration)}
  end

  def handle_event("search_actor_groups", %{"value" => search_term}, socket) do
    actor_id = socket.assigns.selected_actor && socket.assigns.selected_actor.id

    results =
      case Database.search_groups_for_actor(search_term, actor_id, socket.assigns.subject) do
        {:error, _} -> []
        groups -> groups
      end

    {:noreply, merge_state(socket, :actor_group_membership, group_search_results: results)}
  end

  def handle_event("focus_group_search", _params, socket) do
    {:noreply, merge_state(socket, :actor_group_membership, group_search_results: [])}
  end

  def handle_event("blur_group_search", _params, socket) do
    {:noreply, merge_state(socket, :actor_group_membership, group_search_results: nil)}
  end

  def handle_event("add_pending_group", %{"group_id" => group_id}, socket) do
    existing_group_ids = Enum.map(socket.assigns.actor_related.groups, & &1.id)
    pending_ids = Enum.map(socket.assigns.actor_group_membership.pending_group_additions, & &1.id)
    already_exists = group_id in existing_group_ids or group_id in pending_ids

    group =
      Enum.find(
        socket.assigns.actor_group_membership.group_search_results || [],
        &(&1.id == group_id)
      )

    socket =
      if already_exists or is_nil(group) do
        socket
      else
        membership = socket.assigns.actor_group_membership

        assign(
          socket,
          actor_group_membership:
            membership
            |> Map.put(:pending_group_additions, membership.pending_group_additions ++ [group])
            |> Map.put(
              :pending_group_removals,
              Enum.reject(membership.pending_group_removals, &(&1 == group_id))
            )
            |> Map.put(:group_search_results, nil)
        )
      end

    {:noreply, socket}
  end

  def handle_event("remove_pending_group_addition", %{"group_id" => group_id}, socket) do
    additions =
      Enum.reject(
        socket.assigns.actor_group_membership.pending_group_additions,
        &(&1.id == group_id)
      )

    {:noreply, merge_state(socket, :actor_group_membership, pending_group_additions: additions)}
  end

  def handle_event("add_pending_group_removal", %{"group_id" => group_id}, socket) do
    additions =
      Enum.reject(
        socket.assigns.actor_group_membership.pending_group_additions,
        &(&1.id == group_id)
      )

    removals =
      if group_id in socket.assigns.actor_group_membership.pending_group_removals do
        socket.assigns.actor_group_membership.pending_group_removals
      else
        socket.assigns.actor_group_membership.pending_group_removals ++ [group_id]
      end

    {:noreply,
     merge_state(socket, :actor_group_membership,
       pending_group_additions: additions,
       pending_group_removals: removals
     )}
  end

  def handle_event("undo_pending_group_removal", %{"group_id" => group_id}, socket) do
    removals =
      Enum.reject(
        socket.assigns.actor_group_membership.pending_group_removals,
        &(&1 == group_id)
      )

    {:noreply, merge_state(socket, :actor_group_membership, pending_group_removals: removals)}
  end

  def handle_event("create_service_account", %{"actor" => attrs} = params, socket) do
    account = socket.assigns.account

    if Portal.Billing.can_create_service_accounts?(account) do
      attrs = Map.put(attrs, "type", "service_account")
      changeset = changeset(%Actor{type: :service_account}, attrs)
      token_expiration = Map.get(params, "token_expiration")

      result =
        Database.create_service_account_with_token(
          changeset,
          token_expiration,
          socket.assigns.subject,
          &create_actor_token/3
        )

      case result do
        {:ok, {actor, nil}} ->
          socket =
            socket
            |> apply_group_membership_changes(actor, socket.assigns.subject)
            |> reload_live_table!("actors")
            |> push_patch(
              to: ~p"/#{socket.assigns.account}/service_accounts/#{actor.id}"
            )

          {:noreply, socket}

        {:ok, {actor, {_token, encoded_token}}} ->
          socket =
            socket
            |> apply_group_membership_changes(actor, socket.assigns.subject)
            |> reload_live_table!("actors")
            |> merge_state(:actor_related, created_token: encoded_token)
            |> push_patch(
              to: ~p"/#{socket.assigns.account}/service_accounts/#{actor.id}"
            )

          {:noreply, socket}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, actor_form: actor_form_state(to_form(changeset)))}

        {:error, reason} ->
          Logger.error("Failed to create service account",
            reason: inspect(reason),
            account_id: account.id,
            subject_actor_id: socket.assigns.subject.actor.id
          )

          {:noreply,
           put_flash(
             socket,
             :error,
             "A temporary error occurred while creating the service account. Please try again."
           )}
      end
    else
      {:noreply,
       put_flash(socket, :error_inline, "Service account limit reached for your account")}
    end
  end

  def handle_event("save", %{"actor" => attrs}, socket) do
    actor = socket.assigns.selected_actor
    changeset = changeset(actor, attrs)

    case Database.update(changeset, socket.assigns.subject) do
      {:ok, updated_actor} ->
        socket = apply_group_membership_changes(socket, updated_actor, socket.assigns.subject)

        {:noreply,
         socket
         |> put_flash(:success, "Service account updated successfully.")
         |> reload_live_table!("actors")
         |> push_patch(
           to: ~p"/#{socket.assigns.account}/service_accounts/#{updated_actor.id}"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, actor_form: actor_form_state(to_form(changeset)))}
    end
  end

  def handle_event("confirm_disable_actor", _params, socket) do
    {:noreply, merge_state(socket, :actor_panel, confirm_disable_actor: true)}
  end

  def handle_event("cancel_disable_actor", _params, socket) do
    {:noreply, merge_state(socket, :actor_panel, confirm_disable_actor: false)}
  end

  def handle_event("confirm_delete_actor", _params, socket) do
    {:noreply, merge_state(socket, :actor_panel, confirm_delete_actor: true)}
  end

  def handle_event("cancel_delete_actor", _params, socket) do
    {:noreply, merge_state(socket, :actor_panel, confirm_delete_actor: false)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, actor} <- Database.get_actor(id, socket.assigns.subject),
         {:ok, _actor} <- Database.delete(actor, socket.assigns.subject) do
      {:noreply,
       socket
       |> put_flash(:success, "Service account deleted successfully")
       |> reload_live_table!("actors")
       |> push_patch(to: ~p"/#{socket.assigns.account}/service_accounts")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Service account not found")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You are not authorized to delete this service account")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete service account")}
    end
  end

  def handle_event("disable", %{"id" => id}, socket) do
    with {:ok, actor} <- Database.get_actor(id, socket.assigns.subject),
         {:ok, updated_actor} <-
           actor
           |> change()
           |> put_change(:disabled_at, DateTime.utc_now())
           |> Database.update(socket.assigns.subject) do
      socket =
        socket
        |> reload_live_table!("actors")
        |> merge_state(:actor_panel, confirm_disable_actor: false)
        |> maybe_update_actor_assign(id, updated_actor)

      {:noreply, put_flash(socket, :success_inline, "Service account disabled successfully")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Service account not found")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You are not authorized to disable this service account")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to disable service account")}
    end
  end

  def handle_event("enable", %{"id" => id}, socket) do
    with {:ok, actor} <- Database.get_actor(id, socket.assigns.subject) do
      case actor
           |> change()
           |> put_change(:disabled_at, nil)
           |> Database.update(socket.assigns.subject) do
        {:ok, updated_actor} ->
          socket =
            socket
            |> reload_live_table!("actors")
            |> maybe_update_actor_assign(id, updated_actor)

          {:noreply, put_flash(socket, :success_inline, "Service account enabled successfully")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to enable service account")}
      end
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Service account not found")}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You are not authorized to enable this service account")}
    end
  end

  def handle_event("change_tab", %{"tab" => tab}, socket) do
    params = Map.put(socket.assigns.query_params, "tab", tab)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/#{socket.assigns.account}/service_accounts/#{socket.assigns.selected_actor.id}?#{params}"
     )}
  end

  def handle_event("validate_token", params, socket) do
    token_expiration =
      Map.get(params, "token_expiration", socket.assigns.actor_token.token_expiration)

    {:noreply, merge_state(socket, :actor_token, token_expiration: token_expiration)}
  end

  def handle_event("create_token", params, socket) do
    actor = socket.assigns.selected_actor
    token_expiration = Map.get(params, "token_expiration")

    case create_actor_token(actor, token_expiration, socket.assigns.subject) do
      {:ok, {_token, encoded_token}} ->
        tokens = Database.get_client_tokens_for_actor(actor.id, socket.assigns.subject)

        {:noreply,
         socket
         |> merge_state(:actor_related, created_token: encoded_token, tokens: tokens)
         |> merge_state(:actor_token, adding_token: false)}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to create token")}
    end
  end

  def handle_event("confirm_delete_token", %{"id" => token_id}, socket) do
    {:noreply, merge_state(socket, :actor_panel, confirm_delete_token_id: token_id)}
  end

  def handle_event("cancel_delete_token", _params, socket) do
    {:noreply, merge_state(socket, :actor_panel, confirm_delete_token_id: nil)}
  end

  def handle_event("open_add_token_form", _params, socket) do
    default_expiration =
      Date.utc_today()
      |> Date.add(365)
      |> Date.to_iso8601()

    {:noreply,
     merge_state(socket, :actor_token, adding_token: true, token_expiration: default_expiration)}
  end

  def handle_event("cancel_add_token_form", _params, socket) do
    {:noreply, merge_state(socket, :actor_token, adding_token: false)}
  end

  def handle_event("dismiss_created_token", _params, socket) do
    {:noreply, merge_state(socket, :actor_related, created_token: nil)}
  end

  def handle_event("delete_token", %{"id" => token_id}, socket) do
    token = Database.get_client_token_by_id(token_id, socket.assigns.subject)

    if token do
      case Database.delete(token, socket.assigns.subject) do
        {:ok, _} ->
          tokens =
            Database.get_client_tokens_for_actor(
              socket.assigns.selected_actor.id,
              socket.assigns.subject
            )

          {:noreply,
           socket
           |> merge_state(:actor_related, tokens: tokens)
           |> merge_state(:actor_panel, confirm_delete_token_id: nil)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete token")}
      end
    else
      {:noreply, put_flash(socket, :error, "Token not found")}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    actor = socket.assigns.selected_actor

    cond do
      is_nil(actor) ->
        {:noreply, socket}

      topic == "presences:actor_clients:" <> actor.id ->
        tokens = Database.get_client_tokens_for_actor(actor.id, socket.assigns.subject)
        {:noreply, merge_state(socket, :actor_related, tokens: tokens)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_actors_update!(socket, list_opts) do
    with {:ok, actors, metadata} <- Database.list_actors(socket.assigns.subject, list_opts) do
      {:ok, assign(socket, actors: actors, actors_metadata: metadata)}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.page_header>
        <:icon>
          <.icon name="ri-robot-3-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Service Accounts</:title>
        <:description>
          Non-human accounts used for automated access to resources.
        </:description>
        <:action>
          <.docs_action path="/deploy/service-accounts" />
        </:action>
        <:action>
          <.button style="primary" icon="ri-add-line" phx-click="open_new_actor_panel">
            New Service Account
          </.button>
        </:action>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="actors"
          rows={@actors}
          row_id={&"actor-#{&1.id}"}
          row_click={fn actor ->
            ~p"/#{@account}/service_accounts/#{actor.id}?#{@query_params}"
          end}
          row_selected={
            fn actor -> not is_nil(@selected_actor) and actor.id == @selected_actor.id end
          }
          filters={@filters_by_table_id["actors"]}
          filter={@filter_form_by_table_id["actors"]}
          ordered_by={@order_by_table_id["actors"]}
          metadata={@actors_metadata}
          class="flex-1 min-h-0"
        >
          <:col :let={actor} field={{:actors, :name}} label="name">
            <div class="flex items-center gap-2.5">
              <.actor_type_icon_with_badge actor={actor} />
              <div>
                <div class="font-medium text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors">
                  {actor.name}
                </div>
                <div class="font-mono text-[11px] text-[var(--text-tertiary)] mt-0.5">
                  {actor.id}
                </div>
              </div>
            </div>
          </:col>
          <:col :let={actor} label="status" class="w-32">
            <.status_badge status={if is_nil(actor.disabled_at), do: :active, else: :disabled} />
          </:col>
          <:empty>
            <span class="text-sm text-[var(--text-tertiary)]">No service accounts to display.</span>
          </:empty>
        </.live_table>
      </div>

      <.actor_panel
        account={@account}
        actor={@selected_actor}
        query_params={@query_params}
        subject={@subject}
        panel={@actor_panel}
        form_state={@actor_form}
        related_state={@actor_related}
        token_state={@actor_token}
        group_membership_state={@actor_group_membership}
      />
    </div>
    """
  end

  defp base_actor_assigns do
    [
      actor_panel: actor_panel_state(),
      actor_form: actor_form_state(),
      actor_related: actor_related_state(),
      actor_token: actor_token_state(),
      actor_group_membership: actor_group_membership_state()
    ]
  end

  defp actor_panel_state(overrides \\ []) do
    %{
      view: :detail,
      active_tab: "tokens",
      creating_actor: false,
      new_actor_type: nil,
      is_last_admin: false,
      welcome_email_sent: false,
      confirm_disable_actor: false,
      confirm_delete_actor: false,
      confirm_delete_identity_id: nil,
      confirm_delete_token_id: nil,
      confirm_delete_session_id: nil
    }
    |> Map.merge(Map.new(overrides))
  end

  defp actor_form_state(form \\ nil), do: %{form: form}

  defp actor_related_state(overrides \\ []) do
    %{identities: [], groups: [], tokens: [], sessions: [], created_token: nil}
    |> Map.merge(Map.new(overrides))
  end

  defp actor_token_state(overrides \\ []) do
    %{adding_token: false, token_expiration: ""}
    |> Map.merge(Map.new(overrides))
  end

  defp actor_group_membership_state(overrides \\ []) do
    %{pending_group_additions: [], pending_group_removals: [], group_search_results: nil}
    |> Map.merge(Map.new(overrides))
  end

  defp merge_state(socket, key, updates) do
    update(socket, key, &Map.merge(&1, Map.new(updates)))
  end

  defp default_token_expiration do
    Date.utc_today() |> Date.add(365) |> Date.to_iso8601()
  end

  defp selected_actor_matches?(socket, id) do
    match?(%{id: ^id}, socket.assigns.selected_actor)
  end

  defp subscribe_client_tokens(socket, actor) do
    if connected?(socket) and socket.assigns.client_tokens_subscribed_actor_id != actor.id do
      if prev_id = socket.assigns.client_tokens_subscribed_actor_id do
        Presence.Clients.Actor.unsubscribe(prev_id)
      end

      Presence.Clients.Actor.subscribe(actor.id)
      assign(socket, client_tokens_subscribed_actor_id: actor.id)
    else
      socket
    end
  end

  defp unsubscribe_client_tokens(socket) do
    cond do
      not connected?(socket) ->
        socket

      id = socket.assigns[:client_tokens_subscribed_actor_id] ->
        Presence.Clients.Actor.unsubscribe(id)
        assign(socket, client_tokens_subscribed_actor_id: nil)

      true ->
        socket
    end
  end

  defp maybe_update_actor_assign(socket, id, updated_actor) do
    if Map.get(socket.assigns, :selected_actor) && socket.assigns.selected_actor.id == id do
      assign(socket, selected_actor: updated_actor)
    else
      socket
    end
  end

  defp handle_actor_show(socket, id, params) do
    case Database.get_actor(id, socket.assigns.subject) do
      {:ok, actor} ->
        tokens = Database.get_client_tokens_for_actor(actor.id, socket.assigns.subject)
        groups = Database.get_groups_for_actor(actor.id, socket.assigns.subject)
        active_tab = Map.get(params, "tab", "tokens")
        created_token = socket.assigns.actor_related.created_token

        socket
        |> assign(selected_actor: actor)
        |> assign(base_actor_assigns())
        |> assign(
          actor_panel: actor_panel_state(view: :detail, active_tab: active_tab),
          actor_related:
            actor_related_state(tokens: tokens, groups: groups, created_token: created_token)
        )
        |> subscribe_client_tokens(actor)

      _ ->
        socket
        |> put_flash(:error, "Service account not found")
        |> push_navigate(to: ~p"/#{socket.assigns.account}/service_accounts")
    end
  end

  defp changeset(actor, attrs) do
    cast(actor, attrs, [:name, :type])
  end

  defp apply_group_membership_changes(socket, actor, subject) do
    Enum.each(socket.assigns.actor_group_membership.pending_group_additions, fn group ->
      Database.add_group_member(group.id, actor, subject)
    end)

    Enum.each(socket.assigns.actor_group_membership.pending_group_removals, fn group_id ->
      Database.remove_group_member(group_id, actor, subject)
    end)

    assign(socket, actor_group_membership: actor_group_membership_state())
  end

  defp parse_date_to_datetime(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> DateTime.new!(date, ~T[23:59:59], "Etc/UTC")
      {:error, _} -> nil
    end
  end

  defp create_actor_token(_actor, nil, _subject), do: {:ok, nil}
  defp create_actor_token(_actor, "", _subject), do: {:ok, nil}

  defp create_actor_token(actor, token_expiration, subject) do
    case parse_date_to_datetime(token_expiration) do
      nil ->
        {:error, :invalid_date}

      expires_at ->
        case Authentication.create_headless_client_token(actor, %{"expires_at" => expires_at}, subject) do
          {:ok, token} ->
            {:ok, {token, Authentication.encode_fragment!(token)}}

          error ->
            error
        end
    end
  end

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.Actor
    alias Portal.ClientSession
    alias Portal.ClientToken
    alias Portal.Presence
    alias Portal.Safe
    alias Portal.Repo.Filter
    alias Portal.Repo.OffsetPaginator

    defp index_query do
      from(actors in Actor, as: :actors)
      |> where([actors: actors], actors.type == :service_account)
    end

    def cursor_fields do
      [{:actors, :asc, :inserted_at}, {:actors, :asc, :id}]
    end

    def filters do
      [
        %Filter{
          name: :name_or_email,
          title: "Name",
          type: {:string, :websearch},
          fun: &filter_by_name/2
        },
        %Filter{
          name: :status,
          title: "Status",
          type: :string,
          values: [{"Active", "active"}, {"Disabled", "disabled"}],
          fun: &filter_by_status/2
        }
      ]
    end

    def filter_by_name(queryable, search_term) do
      {queryable,
       dynamic([actors: actors], fulltext_search(actors.name, ^search_term))}
    end

    def filter_by_status(queryable, "active") do
      {queryable, dynamic([actors: actors], is_nil(actors.disabled_at))}
    end

    def filter_by_status(queryable, "disabled") do
      {queryable, dynamic([actors: actors], not is_nil(actors.disabled_at))}
    end

    def list_actors(subject, opts \\ []) do
      {filter, opts} = Keyword.pop(opts, :filter, [])
      {order_by, opts} = Keyword.pop(opts, :order_by, [])
      {page_opts, _opts} = Keyword.pop(opts, :page, [])

      with {:ok, paginator_opts} <- OffsetPaginator.init(__MODULE__, order_by, page_opts),
           {:ok, filtered_query} <- Filter.filter(index_query(), __MODULE__, filter),
           count when is_integer(count) <-
             Safe.aggregate(Safe.scoped(filtered_query, subject, :replica), :count),
           actor_ids <- list_actor_ids(filtered_query, paginator_opts, subject),
           {actor_ids, metadata} <- OffsetPaginator.metadata(actor_ids, paginator_opts) do
        actors = fetch_actors_page(actor_ids, subject)
        {:ok, actors, %{metadata | count: count}}
      else
        {:error, :unauthorized} = error -> error
        {:error, _reason} = error -> error
      end
    end

    defp list_actor_ids(filtered_query, paginator_opts, subject) do
      filtered_query
      |> select([actors: actors], actors.id)
      |> OffsetPaginator.query(paginator_opts)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    defp fetch_actors_page([], _subject), do: []

    defp fetch_actors_page(actor_ids, subject) do
      actors =
        from(a in Actor, as: :actors)
        |> where([actors: a], a.id in ^actor_ids)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> Enum.map(&%{&1 | identity_count: 0})

      actors_by_id = Map.new(actors, &{&1.id, &1})
      Enum.map(actor_ids, &Map.fetch!(actors_by_id, &1))
    end

    def get_actor(id, subject) do
      result =
        from(a in Actor, as: :actors)
        |> where([actors: a], a.id == ^id)
        |> where([actors: a], a.type == :service_account)
        |> Safe.scoped(subject, :replica)
        |> Safe.one(fallback_to_primary: true)

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        actor -> {:ok, actor}
      end
    end

    def get_client_tokens_for_actor(actor_id, subject) do
      tokens =
        from(c in ClientToken, as: :client_tokens)
        |> where([client_tokens: c], c.actor_id == ^actor_id)
        |> order_by([client_tokens: c], desc: c.inserted_at)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()

      tokens
      |> preload_latest_sessions_for_tokens(subject)
      |> Presence.Clients.preload_client_tokens_presence()
    end

    defp preload_latest_sessions_for_tokens(tokens, subject) do
      token_ids = Enum.map(tokens, & &1.id)

      sessions_by_token_id =
        from(s in ClientSession,
          where: s.client_token_id in ^token_ids,
          distinct: s.client_token_id,
          order_by: [asc: s.client_token_id, desc: s.inserted_at]
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> Map.new(&{&1.client_token_id, &1})

      Enum.map(tokens, fn token ->
        %{token | latest_session: Map.get(sessions_by_token_id, token.id)}
      end)
    end

    def get_client_token_by_id(token_id, subject) do
      from(c in ClientToken, as: :client_tokens)
      |> where([client_tokens: c], c.id == ^token_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def get_groups_for_actor(actor_id, subject) do
      from(g in Portal.Group, as: :groups)
      |> join(:inner, [groups: g], m in Portal.Membership,
        on: m.group_id == g.id and m.account_id == g.account_id,
        as: :membership
      )
      |> where([membership: m], m.actor_id == ^actor_id)
      |> order_by([groups: g], asc: g.name)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def create_service_account_with_token(changeset, token_expiration, subject, token_creator_fn) do
      Safe.transact(fn ->
        with {:ok, actor} <- create(changeset, subject),
             {:ok, token_result} <- token_creator_fn.(actor, token_expiration, subject) do
          {:ok, {actor, token_result}}
        end
      end)
    end

    defp create(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def update(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete(record, subject) do
      record
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def search_groups_for_actor(search_term, actor_id, subject) do
      query =
        from(g in Portal.Group, as: :groups)
        |> where([groups: g], g.type == :static)
        |> where([groups: g], ilike(g.name, ^"%#{search_term}%"))
        |> limit(10)

      query =
        if actor_id do
          existing_group_ids =
            from(m in Portal.Membership, where: m.actor_id == ^actor_id, select: m.group_id)

          where(query, [groups: g], g.id not in subquery(existing_group_ids))
        else
          query
        end

      query
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> case do
        {:error, _} = err -> err
        groups -> groups
      end
    end

    def add_group_member(group_id, actor, subject) do
      import Ecto.Changeset

      %Portal.Membership{}
      |> change(%{account_id: actor.account_id, group_id: group_id, actor_id: actor.id})
      |> Portal.Membership.changeset()
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def remove_group_member(group_id, actor, subject) do
      from(m in Portal.Membership, as: :memberships)
      |> where([memberships: m], m.group_id == ^group_id and m.actor_id == ^actor.id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!()
      |> then(&(Safe.scoped(&1, subject) |> Safe.delete()))
    end
  end
end
