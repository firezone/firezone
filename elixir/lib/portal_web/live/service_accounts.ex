defmodule PortalWeb.ServiceAccounts do
  use PortalWeb, :live_view

  alias __MODULE__.Database
  alias PortalWeb.Actors

  alias Portal.Actor
  alias Portal.Authentication
  alias Portal.Changes.Change
  alias Portal.DeviceToken
  alias Portal.Presence
  alias Portal.PubSub
  alias Phoenix.LiveView.AsyncResult

  import Ecto.Changeset

  require Logger

  @form_events ~w[validate save create_service_account]

  @selected_actor_events ~w[open_actor_edit_form cancel_actor_edit_form save create_token delete_token add_actor_to_group remove_actor_from_group]

  def mount(_params, _session, socket) do
    subject = socket.assigns.subject

    if connected?(socket) do
      :ok = PubSub.Changes.subscribe(socket.assigns.account.id, :actors)
      :ok = Presence.Devices.Account.subscribe(socket.assigns.account.id)
    end

    socket =
      socket
      |> assign(page_title: "Service accounts")
      |> assign(stale: false)
      |> assign_async(:actors_count, fn -> {:ok, %{actors_count: Database.count_actors(subject)}} end)
      |> assign(
        selected_actor: nil,
        portal_sessions_subscribed_actor_id: nil
      )
      |> assign(base_actor_assigns())
      |> assign(actors: [], actor_tokens: %{}, actors_metadata: %Portal.Repo.OffsetPaginator.Metadata{})
      |> LiveTable.assign_live_table("actors",
        query_module: Database,
        sortable_fields: [
          {:actors, :name},
          {:actors, :updated_at}
        ],
        loader: &load_actors/2
      )
      |> PortalWeb.Live.Helpers.drop_stale_events(&stale_event?/2)

    {:ok, socket}
  end

  # New Service Account Panel
  def handle_params(params, uri, %{assigns: %{live_action: :new}} = socket) do
    socket = LiveTable.handle_live_tables_params(socket, params, uri)
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
    socket = LiveTable.handle_live_tables_params(socket, params, uri)

    if selected_actor_matches?(socket, id) do
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

      {:noreply, socket}
    else
      {:noreply, handle_actor_show(socket, id, params)}
    end
  end

  # Edit Panel
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    with {:ok, actor} <- Database.get_actor(id, socket.assigns.subject) do
      socket = LiveTable.handle_live_tables_params(socket, params, uri)
      changeset = changeset(actor, %{})
      same_actor? = selected_actor_matches?(socket, actor.id)
      related = socket.assigns.actor_related

      {:noreply,
       socket
       |> assign(selected_actor: actor)
       |> assign(base_actor_assigns())
       |> assign(
         actor_panel: actor_panel_state(view: :edit, is_last_admin: false),
         actor_form: actor_form_state(to_form(changeset)),
         actor_group_membership: actor_group_membership_state()
       )
       |> restore_or_load_related(actor, same_actor?, related)}
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

  # Default handler, list view
  def handle_params(params, uri, socket) do
    socket = LiveTable.handle_live_tables_params(socket, params, uri)

    socket =
      socket
      |> assign(selected_actor: nil)
      |> assign(base_actor_assigns())

    {:noreply, socket}
  end

  def handle_event(event, params, socket)
      when event in ["paginate", "order_by", "filter", "reload", "table_row_click", "change_limit"],
      do: LiveTable.handle_live_table_event(event, params, socket)

  def handle_event("close_panel", _params, %{assigns: %{actor_panel: %{creating_actor: true}}} = socket) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts"))}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts"))}
  end

  def handle_event("handle_keydown", _params, %{assigns: %{live_action: :edit}} = socket)
      when not is_nil(socket.assigns.selected_actor) do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts/#{socket.assigns.selected_actor.id}"))}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_actor) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts"))}
  end

  def handle_event(
        "handle_keydown",
        _params,
        %{assigns: %{actor_panel: %{creating_actor: true}}} = socket
      ) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts"))}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_new_actor_panel", _params, socket) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts/new"))}
  end

  def handle_event("open_actor_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts/#{socket.assigns.selected_actor.id}/edit"))}
  end

  def handle_event("cancel_actor_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts/#{socket.assigns.selected_actor.id}"))}
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
    existing_group_ids = Enum.map(Actors.Details.loaded(socket.assigns.actor_related.groups), & &1.group.id)
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

  def handle_event("add_actor_to_group", %{"group_id" => group_id}, socket) do
    actor = socket.assigns.selected_actor
    subject = socket.assigns.subject

    result =
      case Actors.Details.fetch_manual_group(group_id, subject) do
        %Portal.Group{} = group -> Database.add_group_member(group.id, actor, subject)
        _ -> {:error, :not_found}
      end

    {:noreply, after_inline_membership_change(socket, result, "Could not add to the group.")}
  end

  def handle_event("remove_actor_from_group", %{"group_id" => group_id}, socket) do
    actor = socket.assigns.selected_actor
    subject = socket.assigns.subject

    result =
      case Actors.Details.fetch_manual_group(group_id, subject) do
        %Portal.Group{} = group -> Database.remove_group_member(group.id, actor, subject)
        _ -> {:error, :not_found}
      end

    {:noreply, after_inline_membership_change(socket, result, "Could not remove from the group.")}
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
            |> LiveTable.reload_live_table!("actors")
            |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts/#{actor.id}"))

          {:noreply, socket}

        {:ok, {actor, {_token, encoded_token}}} ->
          socket =
            socket
            |> apply_group_membership_changes(actor, socket.assigns.subject)
            |> LiveTable.reload_live_table!("actors")
            |> merge_state(:actor_related, created_token: encoded_token)
            |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts/#{actor.id}"))

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
       put_flash(socket, :error, "Service account limit reached for your account")}
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
         |> LiveTable.reload_live_table!("actors")
         |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts/#{updated_actor.id}"))}

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
       |> LiveTable.reload_live_table!("actors")
       |> push_patch(to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts"))}
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
           |> put_change(:is_disabled, true)
           |> Database.update(socket.assigns.subject) do
      socket =
        socket
        |> LiveTable.reload_live_table!("actors")
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
    with {:ok, actor} <- Database.get_actor(id, socket.assigns.subject),
         :ok <- Portal.Billing.check_actor_enable_limits(socket.assigns.account, actor) do
      case actor
           |> change()
           |> put_change(:is_disabled, false)
           |> Database.update(socket.assigns.subject) do
        {:ok, updated_actor} ->
          socket =
            socket
            |> LiveTable.reload_live_table!("actors")
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

      {:error, :service_accounts_limit_reached} ->
        {:noreply, put_flash(socket, :error, "Service account limit reached for your account")}
    end
  end

  def handle_event(
        "change_tab",
        %{"tab" => tab},
        %{assigns: %{selected_actor: %Actor{} = actor}} = socket
      ) do
    {:noreply, push_patch(socket, to: LiveTable.live_table_path(socket, ~p"/#{socket.assigns.account}/service_accounts/#{actor}", tab: tab))}
  end

  def handle_event("change_tab", _params, %{assigns: %{selected_actor: nil}} = socket) do
    {:noreply, socket}
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
         |> merge_state(:actor_related, created_token: encoded_token)
         |> Actors.Details.put_related(:tokens, tokens)
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
    token =
      Database.get_client_token_by_id(
        token_id,
        socket.assigns.selected_actor.id,
        socket.assigns.subject
      )

    if token do
      case Database.delete_client_token(token, socket.assigns.subject) do
        {:ok, _} ->
          tokens =
            Database.get_client_tokens_for_actor(
              socket.assigns.selected_actor.id,
              socket.assigns.subject
            )

          {:noreply,
           socket
           |> Actors.Details.put_related(:tokens, tokens)
           |> merge_state(:actor_panel, confirm_delete_token_id: nil)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete token")}
      end
    else
      {:noreply, put_flash(socket, :error, "Token not found")}
    end
  end

  def handle_info(%Change{op: :insert, struct: %Actor{type: :service_account}} = change, socket) do
    {:noreply,
     socket
     |> update(:actors_count, fn
       %AsyncResult{ok?: true} = ar -> AsyncResult.ok(ar, ar.result + 1)
       ar -> ar
     end)
     |> mark_stale_if_unreflected(change)}
  end

  def handle_info(%Change{op: :delete, old_struct: %Actor{type: :service_account}} = change, socket) do
    {:noreply,
     socket
     |> update(:actors_count, fn
       %AsyncResult{ok?: true} = ar -> AsyncResult.ok(ar, max(ar.result - 1, 0))
       ar -> ar
     end)
     |> mark_stale_if_unreflected(change)}
  end

  def handle_info(%Change{struct: %Actor{type: :service_account}} = change, socket) do
    {:noreply, mark_stale_if_unreflected(socket, change)}
  end

  # The :actors topic carries every actor type, so this page also sees users and
  # API clients, which have pages of their own and change nothing here.
  def handle_info(%Change{struct: %Actor{}}, socket), do: {:noreply, socket}
  def handle_info(%Change{old_struct: %Actor{}}, socket), do: {:noreply, socket}

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic, payload: payload},
        socket
      ) do
    actor = socket.assigns.selected_actor

    cond do
      is_nil(actor) ->
        {:noreply, socket}

      topic == "presences:account_devices:" <> socket.assigns.account.id and
          Presence.Devices.diff_includes_actor?(payload, actor.id) ->
        {:noreply, start_related(socket, actor, [:tokens, :devices])}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(message, socket), do: PortalWeb.Live.Helpers.handle_info_fallback(message, socket)

  def handle_async({:actor_related, _key} = name, result, socket) do
    {:noreply, Actors.Details.handle_related_async(name, result, socket)}
  end

  defp load_actors(subject, list_opts) do
    with {:ok, actors, metadata} <- Database.list_actors(subject, list_opts) do
      actor_tokens = Database.list_token_expiries(actors, subject)
      {:ok, %{actors: actors, actor_tokens: actor_tokens, actors_metadata: metadata}}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <Page.page_header>
        <:title>Service accounts</:title>
        <:description>
          Accounts that headless Clients use to connect without a person.
        </:description>
        <:action>
          <Navigation.docs_action show_label size="md" path="/deploy/service-accounts" />
        </:action>
        <:action>
          <Form.button style="primary" icon="ri-add-line" phx-click={Page.instant("Add a service account", size: "xl") |> JS.push("open_new_actor_panel")}>
            Add a service account
          </Form.button>
        </:action>
        <:stats>
          <.async_result :let={count} assign={@actors_count}>
            <:loading><Core.badge type="primary">Loading...</Core.badge></:loading>
            <Core.dual_badge type="primary">
              <:left>{count}</:left>
              <:right>Total</:right>
            </Core.dual_badge>
          </.async_result>
        </:stats>
      </Page.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <LiveTable.live_table
          id="actors"
          modal_size="xl"
          loading={@loading_by_table_id["actors"]}
          query_error={@query_error_by_table_id["actors"]}
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
          stale={@stale}
          class="flex-1 min-h-0"
        >
          <:col :let={actor} field={{:actors, :name}} label="Name">
            <div class="flex items-center gap-2.5 min-w-0">
              <Actors.Components.actor_avatar account={@account} actor={actor} />
              <div class="min-w-0">
                <div class="font-medium text-fg truncate">{actor.name}</div>
                <div class="text-xs text-muted truncate">
                  <Actors.Components.token_expiry tokens={Map.get(@actor_tokens, actor.id, [])} />
                </div>
              </div>
            </div>
          </:col>
          <:col :let={actor} label="Groups" class="w-1/3">
            <Actors.Components.group_links account={@account} groups={actor.groups} />
          </:col>
          <:col :let={actor} label="Status" filter={:status} class="w-28">
            <Actors.Components.actor_status_badge is_disabled={actor.is_disabled} />
          </:col>
          <:col :let={actor} label="Last active" class="w-36 text-right">
            <Actors.Components.last_active actor={actor} />
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <Core.icon name="ri-robot-3-line" class="w-6 h-6 text-faint" />
              <div class="text-center">
                <p class="text-sm font-medium text-fg">No service accounts yet</p>
                <p class="text-xs text-muted mt-0.5">
                  No service accounts have been created yet.
                </p>
              </div>
              <Form.button
                patch={LiveTable.live_table_path(assigns, ~p"/#{@account}/service_accounts/new")}
                size="sm"
                icon="ri-add-line"
              >
                Add a service account
              </Form.button>
            </div>
          </:empty>
        </LiveTable.live_table>
      </div>

      <Actors.Components.actor_panel
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

  defp stale_event?(event, %{actor_form: %{form: nil}}) when event in @form_events, do: true
  defp stale_event?(event, %{selected_actor: nil}) when event in @selected_actor_events, do: true
  defp stale_event?(_event, _assigns), do: false

  defp base_actor_assigns do
    [
      actor_panel: actor_panel_state(),
      actor_form: actor_form_state(),
      actor_related: Actors.Details.related_state(),
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

  defp actor_form_state(form \\ nil), do: %{form: form, pending_email_change: nil}

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

  defp mark_stale_if_unreflected(socket, change) do
    LiveTable.mark_stale_unless_reflected(socket, "actors", socket.assigns.actors, change)
  end

  defp default_token_expiration do
    Date.utc_today() |> Date.add(365) |> Date.to_iso8601()
  end

  defp selected_actor_matches?(socket, id) do
    match?(%{id: ^id}, socket.assigns.selected_actor)
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
        active_tab = Map.get(params, "tab", "tokens")
        created_token = socket.assigns.actor_related.created_token

        socket
        |> assign(selected_actor: actor)
        |> assign(base_actor_assigns())
        |> assign(
          actor_panel: actor_panel_state(view: :detail, active_tab: active_tab),
          actor_related: Actors.Details.related_state(created_token)
        )
        |> load_related(actor)

      _ ->
        socket
        |> put_flash(:error, "Service account not found")
        |> push_navigate(to: ~p"/#{socket.assigns.account}/service_accounts")
    end
  end

  defp restore_or_load_related(socket, _actor, true, related), do: assign(socket, actor_related: related)
  defp restore_or_load_related(socket, actor, false, _related), do: load_related(socket, actor)

  defp load_related(socket, actor) do
    socket
    |> Actors.Details.put_related(:identities, [])
    |> Actors.Details.put_related(:sessions, [])
    |> start_related(actor, [:groups, :tokens, :devices, :reach])
  end

  defp start_related(socket, actor, keys) do
    Actors.Details.start_related(socket, actor, keys, &related_records/3)
  end

  defp related_records(:groups, actor_id, subject), do: Database.get_groups_for_actor(actor_id, subject)
  defp related_records(:tokens, actor_id, subject), do: Database.get_client_tokens_for_actor(actor_id, subject)
  defp related_records(:devices, actor_id, subject), do: Actors.Details.list_devices(actor_id, subject)
  defp related_records(:reach, actor_id, subject), do: Actors.Details.list_reach(actor_id, subject)

  defp changeset(actor, attrs) do
    cast(actor, attrs, [:name, :type])
  end

  defp apply_group_membership_changes(socket, actor, subject) do
    addition_results =
      Enum.map(socket.assigns.actor_group_membership.pending_group_additions, fn group ->
        Database.add_group_member(group.id, actor, subject)
      end)

    removal_results =
      Enum.map(socket.assigns.actor_group_membership.pending_group_removals, fn group_id ->
        Database.remove_group_member(group_id, actor, subject)
      end)

    errors =
      (addition_results ++ removal_results)
      |> Enum.filter(&match?({:error, _}, &1))

    socket =
      socket
      |> assign(actor_group_membership: actor_group_membership_state())
      |> refresh_actor_groups(actor, subject)

    if Enum.empty?(errors) do
      socket
    else
      put_flash(socket, :error, "Failed to update some group memberships.")
    end
  end

  defp after_inline_membership_change(socket, {:ok, _membership}, _message) do
    socket
    |> assign(actor_group_membership: actor_group_membership_state())
    |> refresh_actor_groups(socket.assigns.selected_actor, socket.assigns.subject)
    |> LiveTable.reload_live_table!("actors")
  end

  defp after_inline_membership_change(socket, _result, message) do
    put_flash(socket, :error, message)
  end

  defp refresh_actor_groups(socket, actor, subject) do
    socket
    |> Actors.Details.put_related(:groups, Database.get_groups_for_actor(actor.id, subject))
    |> Actors.Details.put_related(:reach, Actors.Details.list_reach(actor.id, subject))
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
        case Authentication.create_non_interactive_client_token(
               actor,
               %{"expires_at" => expires_at},
               subject
             ) do
          {:ok, token} ->
            {:ok, {token, Authentication.encode_fragment!(token)}}

          error ->
            error
        end
    end
  end

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset, only: [change: 2]
    import Portal.Repo.Query
    alias Portal.Actor
    alias Portal.DeviceToken
    alias Portal.Device
    alias Portal.Presence
    alias Portal.Safe
    alias Portal.Repo.Filter
    alias Portal.Repo.OffsetPaginator

    def count_actors(subject) do
      from(a in Actor, as: :actors)
      |> where([actors: a], a.type == :service_account)
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

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
      {queryable, dynamic([actors: actors], actors.is_disabled == false)}
    end

    def filter_by_status(queryable, "disabled") do
      {queryable, dynamic([actors: actors], actors.is_disabled == true)}
    end

    def list_actors(subject, opts \\ []) do
      {filter, opts} = Keyword.pop(opts, :filter, [])
      {order_by, opts} = Keyword.pop(opts, :order_by, [])
      {page_opts, _opts} = Keyword.pop(opts, :page, [])

      with {:ok, paginator_opts} <- OffsetPaginator.init(__MODULE__, order_by, page_opts),
           {:ok, filtered_query} <- Filter.filter(index_query(), __MODULE__, filter),
           count when is_integer(count) <-
             Safe.aggregate(Safe.scoped(filtered_query, subject), :count),
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
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    defp fetch_actors_page([], _subject), do: []

    defp fetch_actors_page(actor_ids, subject) do
      actors =
        from(a in Actor, as: :actors)
        |> where([actors: a], a.id in ^actor_ids)
        |> Safe.scoped(subject)
        |> Safe.all()

      actors_by_id = Map.new(actors, &{&1.id, &1})

      actor_ids
      |> Enum.map(&Map.get(actors_by_id, &1))
      |> Enum.reject(&is_nil/1)
      |> PortalWeb.Actors.Details.put_list_details(subject)
    end

    def list_token_expiries([], _subject), do: %{}

    def list_token_expiries(actors, subject) do
      ids = Enum.map(actors, & &1.id)

      from(t in DeviceToken,
        where: t.actor_id in ^ids,
        select: {t.actor_id, %{expires_at: t.expires_at}}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        tokens when is_list(tokens) -> Enum.group_by(tokens, &elem(&1, 0), &elem(&1, 1))
        _error -> %{}
      end
    end

    def get_actor(id, subject) do
      result =
        from(a in Actor, as: :actors)
        |> where([actors: a], a.id == ^id)
        |> where([actors: a], a.type == :service_account)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        actor -> {:ok, actor}
      end
    end

    def get_client_tokens_for_actor(actor_id, subject) do
      tokens =
        from(c in DeviceToken, as: :client_tokens)
        |> where([client_tokens: c], c.actor_id == ^actor_id)
        |> order_by([client_tokens: c], desc: c.inserted_at)
        |> Safe.scoped(subject)
        |> Safe.all()

      tokens
      |> preload_last_used_devices_for_tokens(subject)
      |> Presence.Devices.preload_client_tokens_presence()
    end

    defp preload_last_used_devices_for_tokens(tokens, subject) do
      token_ids = Enum.map(tokens, & &1.id)

      devices_by_token_id =
        from(d in Device,
          where: d.token_id in ^token_ids,
          distinct: d.token_id,
          order_by: [asc: d.token_id, desc: d.last_seen_at]
        )
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Map.new(&{&1.token_id, &1})

      Enum.map(tokens, fn token ->
        %{token | last_used_device: Map.get(devices_by_token_id, token.id)}
      end)
    end

    def get_client_token_by_id(token_id, actor_id, subject) do
      from(c in DeviceToken, as: :client_tokens)
      |> where([client_tokens: c], c.id == ^token_id and c.actor_id == ^actor_id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    def delete_client_token(token, subject) do
      from(t in DeviceToken, where: t.account_id == ^token.account_id and t.id == ^token.id)
      |> Portal.Authentication.delete_client_tokens(subject)
      |> case do
        {:error, :unauthorized} = error -> error
        {_count, _} -> {:ok, token}
      end
    end

    def get_groups_for_actor(actor_id, subject) do
      from(g in Portal.Group, as: :groups)
      |> join(:inner, [groups: g], m in Portal.Membership,
        on: m.group_id == g.id and m.account_id == g.account_id,
        as: :membership
      )
      |> where([membership: m], m.actor_id == ^actor_id)
      |> where([groups: g], is_nil(g.resource_id))
      |> order_by([groups: g], asc: g.name)
      |> select([groups: g], %{group: g, directory_type: nil, directory_name: nil})
      |> Safe.scoped(subject)
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
        |> where([groups: g], g.type == :static and is_nil(g.resource_id))
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
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _} = err -> err
        groups -> groups
      end
    end

    def add_group_member(group_id, actor, subject) do
      %Portal.Membership{}
      |> change(%{account_id: actor.account_id, group_id: group_id, actor_id: actor.id})
      |> Portal.Membership.changeset()
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def remove_group_member(group_id, actor, subject) do
      with %Portal.Membership{} = membership <- fetch_membership(group_id, actor, subject) do
        Safe.scoped(membership, subject) |> Safe.delete()
      end
    end

    defp fetch_membership(group_id, actor, subject) do
      from(m in Portal.Membership, as: :memberships)
      |> where([memberships: m], m.group_id == ^group_id and m.actor_id == ^actor.id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end
  end
end
