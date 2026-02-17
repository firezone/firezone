defmodule PortalWeb.Actors do
  use PortalWeb, :live_view

  alias __MODULE__.Database

  alias Portal.Actor
  alias Portal.Authentication
  alias Portal.Presence
  alias Portal.ExternalIdentity
  alias Portal.PortalSession
  alias Portal.ClientToken

  import Ecto.Changeset
  import PortalWeb.Clients.Components, only: [client_os_icon_name: 1]

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Actors")
      |> assign(
        selected_actor: nil,
        panel_view: :detail,
        form: nil,
        active_tab: "identities",
        identities: [],
        groups: [],
        tokens: [],
        sessions: [],
        created_token: nil,
        confirm_disable_actor: false,
        confirm_delete_actor: false,
        confirm_delete_identity_id: nil,
        confirm_delete_token_id: nil,
        confirm_delete_session_id: nil,
        portal_sessions_subscribed_actor_id: nil,
        client_tokens_subscribed_actor_id: nil,
        welcome_email_sent: false,
        is_last_admin: false,
        adding_token: false,
        token_expiration: "",
        creating_actor: false,
        new_actor_type: nil,
        pending_group_additions: [],
        pending_group_removals: [],
        group_search_results: nil
      )
      |> assign_live_table("actors",
        query_module: Database,
        sortable_fields: [
          {:actors, :name},
          {:actors, :email},
          {:actors, :updated_at}
        ],
        callback: &handle_actors_update!/2
      )

    {:ok, socket}
  end

  # Add Actor - Type Selection Modal
  def handle_params(params, uri, %{assigns: %{live_action: :add}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply, assign(socket, actor_type: nil)}
  end

  # Add User Modal
  def handle_params(params, uri, %{assigns: %{live_action: :add_user}} = socket) do
    changeset = changeset(%Actor{}, %{type: :account_user})
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     assign(socket,
       form: to_form(changeset),
       actor_type: :user,
       pending_group_additions: [],
       pending_group_removals: [],
       group_search_results: nil
     )}
  end

  # Add Service Account Modal
  def handle_params(params, uri, %{assigns: %{live_action: :add_service_account}} = socket) do
    # Create an actor struct with type already set
    actor = %Actor{type: :service_account}
    changeset = changeset(actor, %{})
    socket = handle_live_tables_params(socket, params, uri)

    # Default token expiration to 1 year from now
    default_expiration =
      Date.utc_today()
      |> Date.add(365)
      |> Date.to_iso8601()

    {:noreply,
     assign(socket,
       form: to_form(changeset),
       actor_type: :service_account,
       token_expiration: default_expiration,
       pending_group_additions: [],
       pending_group_removals: [],
       group_search_results: nil
     )}
  end

  # Show Actor Panel
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)

    case Database.get_actor(id, socket.assigns.subject) do
      {:ok, actor} ->
        identities = Database.get_identities_for_actor(actor.id, socket.assigns.subject)
        groups = Database.get_groups_for_actor(actor.id, socket.assigns.subject)

        {tokens, sessions} =
          if actor.type == :service_account do
            {Database.get_client_tokens_for_actor(actor.id, socket.assigns.subject), []}
          else
            {Database.get_client_tokens_for_actor(actor.id, socket.assigns.subject),
             Database.get_portal_sessions_for_actor(actor.id, socket.assigns.subject)}
          end

        default_tab = if actor.type == :service_account, do: "tokens", else: "identities"

        socket =
          socket
          |> assign(
            selected_actor: actor,
            panel_view: :detail,
            active_tab: Map.get(params, "tab", default_tab),
            identities: identities,
            groups: groups,
            tokens: tokens,
            sessions: sessions,
            created_token: socket.assigns[:created_token],
            confirm_disable_actor: false,
            confirm_delete_actor: false,
            confirm_delete_identity_id: nil,
            confirm_delete_token_id: nil,
            confirm_delete_session_id: nil,
            welcome_email_sent: false,
            is_last_admin: false,
            adding_token: false,
            token_expiration: "",
            creating_actor: false,
            new_actor_type: nil,
            pending_group_additions: [],
            pending_group_removals: [],
            group_search_results: nil
          )
          |> subscribe_portal_sessions(actor)
          |> subscribe_client_tokens(actor)

        {:noreply, socket}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Actor not found")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/actors")}
    end
  end

  # Add Token Modal
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :add_token}} = socket) do
    with {:ok, actor} <- Database.get_actor(id, socket.assigns.subject) do
      socket = handle_live_tables_params(socket, params, uri)

      # Default token expiration to 1 year from now
      default_expiration =
        Date.utc_today()
        |> Date.add(365)
        |> Date.to_iso8601()

      {:noreply,
       assign(socket,
         actor: actor,
         token_expiration: default_expiration
       )}
    else
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Actor not found")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/actors")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to view this actor")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/actors")}
    end
  end

  # Edit Actor Panel
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    with {:ok, actor} <- Database.get_actor(id, socket.assigns.subject) do
      socket = handle_live_tables_params(socket, params, uri)
      changeset = changeset(actor, %{})

      is_last_admin =
        actor.type == :account_admin_user and
          not other_enabled_admins_exist?(actor, socket.assigns.subject)

      identities = Database.get_identities_for_actor(actor.id, socket.assigns.subject)
      groups = Database.get_groups_for_actor(actor.id, socket.assigns.subject)

      {:noreply,
       assign(socket,
         actor: actor,
         selected_actor: actor,
         panel_view: :edit,
         form: to_form(changeset),
         is_last_admin: is_last_admin,
         identities: identities,
         groups: groups,
         tokens: [],
         sessions: [],
         pending_group_additions: [],
         pending_group_removals: [],
         group_search_results: nil
       )}
    else
      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Actor not found")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/actors")}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, "You are not authorized to view this actor")
         |> push_navigate(to: ~p"/#{socket.assigns.account}/actors")}
    end
  end

  # Default handler - list view, no selection
  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    socket =
      socket
      |> assign(
        selected_actor: nil,
        identities: [],
        groups: [],
        tokens: [],
        sessions: [],
        created_token: nil,
        pending_group_additions: [],
        pending_group_removals: [],
        group_search_results: nil
      )
      |> unsubscribe_portal_sessions()
      |> unsubscribe_client_tokens()

    {:noreply, socket}
  end

  def handle_event(event, params, socket)
      when event in ["paginate", "order_by", "filter", "table_row_click", "change_limit"],
      do: handle_live_table_event(event, params, socket)

  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modal(socket)}
  end

  def handle_event("close_panel", _params, %{assigns: %{creating_actor: true}} = socket) do
    {:noreply,
     assign(socket,
       creating_actor: false,
       new_actor_type: nil,
       form: nil,
       pending_group_additions: [],
       pending_group_removals: [],
       group_search_results: nil
     )}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/actors")}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_actor) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/actors")}
  end

  def handle_event("handle_keydown", _params, %{assigns: %{creating_actor: true}} = socket) do
    {:noreply,
     assign(socket,
       creating_actor: false,
       new_actor_type: nil,
       form: nil,
       pending_group_additions: [],
       pending_group_removals: [],
       group_search_results: nil
     )}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_new_actor_panel", _params, socket) do
    {:noreply,
     assign(socket, creating_actor: true, new_actor_type: nil, selected_actor: nil, form: nil)}
  end

  def handle_event("select_new_actor_type", %{"type" => "user"}, socket) do
    changeset = changeset(%Actor{}, %{type: :account_user})
    {:noreply, assign(socket, new_actor_type: :user, form: to_form(changeset))}
  end

  def handle_event("select_new_actor_type", %{"type" => "service_account"}, socket) do
    changeset = changeset(%Actor{type: :service_account}, %{})

    default_expiration =
      Date.utc_today()
      |> Date.add(365)
      |> Date.to_iso8601()

    {:noreply,
     assign(socket,
       new_actor_type: :service_account,
       form: to_form(changeset),
       token_expiration: default_expiration
     )}
  end

  def handle_event("select_type", %{"type" => type}, socket) do
    query_params = socket.assigns.query_params

    path =
      case type do
        "user" ->
          ~p"/#{socket.assigns.account}/actors/add_user?#{query_params}"

        "service_account" ->
          ~p"/#{socket.assigns.account}/actors/add_service_account?#{query_params}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("open_actor_edit_form", _params, socket) do
    actor = socket.assigns.selected_actor
    changeset = changeset(actor, %{})

    is_last_admin =
      actor.type == :account_admin_user and
        not other_enabled_admins_exist?(actor, socket.assigns.subject)

    {:noreply,
     assign(socket,
       actor: actor,
       panel_view: :edit,
       form: to_form(changeset),
       is_last_admin: is_last_admin,
       pending_group_additions: [],
       pending_group_removals: [],
       group_search_results: nil
     )}
  end

  def handle_event("cancel_actor_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/actors/#{socket.assigns.selected_actor.id}"
     )}
  end

  def handle_event("validate", %{"actor" => attrs} = params, socket) do
    # Use form data which has type already set, or actor from assigns for edit
    actor = socket.assigns[:actor] || socket.assigns.form.data

    changeset =
      actor
      |> changeset(attrs)
      |> Map.put(:action, :validate)

    # Preserve token_expiration for service account form
    token_expiration =
      Map.get(params, "token_expiration", socket.assigns[:token_expiration] || "")

    {:noreply, assign(socket, form: to_form(changeset), token_expiration: token_expiration)}
  end

  def handle_event("search_actor_groups", %{"value" => search_term}, socket) do
    actor_id = socket.assigns[:actor] && socket.assigns.actor.id

    results =
      case Database.search_groups_for_actor(search_term, actor_id, socket.assigns.subject) do
        {:error, _} -> []
        groups -> groups
      end

    {:noreply, assign(socket, group_search_results: results)}
  end

  def handle_event("focus_group_search", _params, socket) do
    {:noreply, assign(socket, group_search_results: [])}
  end

  def handle_event("blur_group_search", _params, socket) do
    {:noreply, assign(socket, group_search_results: nil)}
  end

  def handle_event("add_pending_group", %{"group_id" => group_id}, socket) do
    existing_group_ids = Enum.map(socket.assigns.groups, & &1.id)
    pending_ids = Enum.map(socket.assigns.pending_group_additions, & &1.id)

    already_exists = group_id in existing_group_ids or group_id in pending_ids
    group = Enum.find(socket.assigns.group_search_results || [], &(&1.id == group_id))

    socket =
      if already_exists or is_nil(group) do
        socket
      else
        pending_removals = Enum.reject(socket.assigns.pending_group_removals, &(&1 == group_id))

        assign(socket,
          pending_group_additions: socket.assigns.pending_group_additions ++ [group],
          pending_group_removals: pending_removals,
          group_search_results: nil
        )
      end

    {:noreply, socket}
  end

  def handle_event("remove_pending_group_addition", %{"group_id" => group_id}, socket) do
    additions = Enum.reject(socket.assigns.pending_group_additions, &(&1.id == group_id))
    {:noreply, assign(socket, pending_group_additions: additions)}
  end

  def handle_event("add_pending_group_removal", %{"group_id" => group_id}, socket) do
    # Only for existing memberships; also remove from pending_group_additions if it was there
    additions = Enum.reject(socket.assigns.pending_group_additions, &(&1.id == group_id))

    removals =
      if group_id in socket.assigns.pending_group_removals do
        socket.assigns.pending_group_removals
      else
        socket.assigns.pending_group_removals ++ [group_id]
      end

    {:noreply,
     assign(socket, pending_group_additions: additions, pending_group_removals: removals)}
  end

  def handle_event("undo_pending_group_removal", %{"group_id" => group_id}, socket) do
    removals = Enum.reject(socket.assigns.pending_group_removals, &(&1 == group_id))
    {:noreply, assign(socket, pending_group_removals: removals)}
  end

  def handle_event("create_user", %{"actor" => attrs}, socket) do
    changeset = changeset(%Actor{}, attrs)
    actor_type = get_change(changeset, :type) || :account_user
    account = socket.assigns.account

    # Check billing limits
    cond do
      not Portal.Billing.can_create_users?(account) ->
        {:noreply, put_flash(socket, :error_inline, "User limit reached for your account")}

      actor_type == :account_admin_user and not Portal.Billing.can_create_admin_users?(account) ->
        {:noreply, put_flash(socket, :error_inline, "Admin user limit reached for your account")}

      true ->
        case Database.create(changeset, socket.assigns.subject) do
          {:ok, actor} ->
            socket =
              socket
              |> apply_group_membership_changes(actor, socket.assigns.subject)
              |> put_flash(:success, "User created successfully")
              |> reload_live_table!("actors")
              |> push_patch(to: ~p"/#{socket.assigns.account}/actors/#{actor.id}")

            {:noreply, socket}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end
    end
  end

  def handle_event("create_service_account", %{"actor" => attrs} = params, socket) do
    account = socket.assigns.account

    # Check billing limits
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
        {:ok, {actor, {:ok, nil}}} ->
          socket =
            socket
            |> apply_group_membership_changes(actor, socket.assigns.subject)
            |> reload_live_table!("actors")
            |> push_patch(to: ~p"/#{socket.assigns.account}/actors/#{actor.id}")

          {:noreply, socket}

        {:ok, {actor, {:ok, {_token, encoded_token}}}} ->
          socket =
            socket
            |> apply_group_membership_changes(actor, socket.assigns.subject)
            |> reload_live_table!("actors")
            |> assign(created_token: encoded_token)
            |> push_patch(to: ~p"/#{socket.assigns.account}/actors/#{actor.id}")

          {:noreply, socket}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      {:noreply,
       put_flash(socket, :error_inline, "Service account limit reached for your account")}
    end
  end

  def handle_event("save", %{"actor" => attrs}, socket) do
    actor = socket.assigns.actor
    changeset = changeset(actor, attrs)

    case validate_role_change(changeset, actor, socket) do
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      :ok ->
        save_actor(changeset, socket)
    end
  end

  def handle_event("confirm_disable_actor", _params, socket) do
    {:noreply, assign(socket, confirm_disable_actor: true)}
  end

  def handle_event("cancel_disable_actor", _params, socket) do
    {:noreply, assign(socket, confirm_disable_actor: false)}
  end

  def handle_event("confirm_delete_actor", _params, socket) do
    {:noreply, assign(socket, confirm_delete_actor: true)}
  end

  def handle_event("cancel_delete_actor", _params, socket) do
    {:noreply, assign(socket, confirm_delete_actor: false)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, actor} <- Database.get_actor(id, socket.assigns.subject),
         :ok <- ensure_not_self(actor, socket.assigns.subject),
         {:ok, _actor} <- Database.delete(actor, socket.assigns.subject) do
      {:noreply, handle_success(socket, "Actor deleted successfully")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Actor not found")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to delete this actor")}

      {:error, :self_operation} ->
        {:noreply, put_flash(socket, :error, "You cannot delete yourself")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete actor")}
    end
  end

  def handle_event("disable", %{"id" => id}, socket) do
    with {:ok, actor} <- Database.get_actor(id, socket.assigns.subject),
         :ok <- ensure_not_self(actor, socket.assigns.subject),
         {:ok, updated_actor} <-
           actor
           |> change()
           |> put_change(:disabled_at, DateTime.utc_now())
           |> Database.update(socket.assigns.subject) do
      socket =
        socket
        |> reload_live_table!("actors")
        |> assign(confirm_disable_actor: false)
        |> maybe_update_actor_assign(id, updated_actor)

      {:noreply, put_flash(socket, :success_inline, "Actor disabled successfully")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Actor not found")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to disable this actor")}

      {:error, :self_operation} ->
        {:noreply, put_flash(socket, :error, "You cannot disable yourself")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to disable actor")}
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

          {:noreply, put_flash(socket, :success_inline, "Actor enabled successfully")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to enable actor")}
      end
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Actor not found")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to enable this actor")}
    end
  end

  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/actors/#{socket.assigns.selected_actor.id}?tab=#{tab}"
     )}
  end

  def handle_event("validate_token", params, socket) do
    token_expiration = Map.get(params, "token_expiration", socket.assigns.token_expiration)

    {:noreply, assign(socket, token_expiration: token_expiration)}
  end

  def handle_event("create_token", params, socket) do
    actor = socket.assigns.selected_actor
    token_expiration = Map.get(params, "token_expiration")

    case create_actor_token(actor, token_expiration, socket.assigns.subject) do
      {:ok, {_token, encoded_token}} ->
        tokens = Database.get_client_tokens_for_actor(actor.id, socket.assigns.subject)

        {:noreply,
         assign(socket,
           created_token: encoded_token,
           tokens: tokens,
           adding_token: false
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to create token")}
    end
  end

  def handle_event("confirm_delete_token", %{"id" => token_id}, socket) do
    {:noreply, assign(socket, confirm_delete_token_id: token_id)}
  end

  def handle_event("cancel_delete_token", _params, socket) do
    {:noreply, assign(socket, confirm_delete_token_id: nil)}
  end

  def handle_event("confirm_delete_session", %{"id" => session_id}, socket) do
    {:noreply, assign(socket, confirm_delete_session_id: session_id)}
  end

  def handle_event("cancel_delete_session", _params, socket) do
    {:noreply, assign(socket, confirm_delete_session_id: nil)}
  end

  def handle_event("open_add_token_form", _params, socket) do
    default_expiration =
      Date.utc_today()
      |> Date.add(365)
      |> Date.to_iso8601()

    {:noreply, assign(socket, adding_token: true, token_expiration: default_expiration)}
  end

  def handle_event("cancel_add_token_form", _params, socket) do
    {:noreply, assign(socket, adding_token: false)}
  end

  def handle_event("dismiss_created_token", _params, socket) do
    {:noreply, assign(socket, created_token: nil)}
  end

  def handle_event("delete_token", %{"id" => token_id}, socket) do
    token = Database.get_client_token_by_id(token_id, socket.assigns.subject)

    entity =
      if socket.assigns.selected_actor.type == :service_account, do: "token", else: "session"

    if token do
      case Database.delete(token, socket.assigns.subject) do
        {:ok, _} ->
          tokens =
            Database.get_client_tokens_for_actor(
              socket.assigns.selected_actor.id,
              socket.assigns.subject
            )

          {:noreply, assign(socket, tokens: tokens, confirm_delete_token_id: nil)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete #{entity}")}
      end
    else
      {:noreply, put_flash(socket, :error, "#{String.capitalize(entity)} not found")}
    end
  end

  def handle_event("delete_session", %{"id" => session_id}, socket) do
    session = Database.get_portal_session_by_id(session_id, socket.assigns.subject)

    if session do
      :ok =
        Authentication.delete_portal_session(%PortalSession{
          account_id: socket.assigns.account.id,
          id: session.id
        })

      # Reload sessions for the actor
      sessions =
        Database.get_portal_sessions_for_actor(
          socket.assigns.selected_actor.id,
          socket.assigns.subject
        )

      socket = assign(socket, sessions: sessions, confirm_delete_session_id: nil)
      {:noreply, put_flash(socket, :success_inline, "Session deleted successfully")}
    else
      {:noreply, put_flash(socket, :error, "Session not found")}
    end
  end

  def handle_event("confirm_delete_identity", %{"id" => identity_id}, socket) do
    {:noreply, assign(socket, confirm_delete_identity_id: identity_id)}
  end

  def handle_event("cancel_delete_identity", _params, socket) do
    {:noreply, assign(socket, confirm_delete_identity_id: nil)}
  end

  def handle_event("delete_identity", %{"id" => identity_id}, socket) do
    case Database.get_identity_by_id(identity_id, socket.assigns.subject) do
      nil ->
        {:noreply, put_flash(socket, :error, "Identity not found")}

      identity ->
        case Database.delete(identity, socket.assigns.subject) do
          {:ok, _} ->
            identities =
              Database.get_identities_for_actor(
                socket.assigns.selected_actor.id,
                socket.assigns.subject
              )

            {:noreply, assign(socket, identities: identities, confirm_delete_identity_id: nil)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete identity")}
        end
    end
  end

  def handle_event("send_welcome_email", %{"id" => actor_id}, socket) do
    actor = socket.assigns.selected_actor

    if actor.id == actor_id and actor.email do
      Portal.Mailer.AuthEmail.new_user_email(
        socket.assigns.account,
        actor,
        socket.assigns.subject
      )
      |> Portal.Mailer.deliver_with_rate_limit(
        rate_limit: 3,
        rate_limit_key: {:welcome_email, actor.id},
        rate_limit_interval: :timer.minutes(3)
      )
      |> case do
        {:ok, _} ->
          Process.send_after(self(), :clear_welcome_email_sent, 3000)
          {:noreply, assign(socket, welcome_email_sent: true)}

        {:error, :rate_limited} ->
          socket =
            socket
            |> put_flash(
              :error,
              "You sent too many welcome emails to this address. Please try again later."
            )

          {:noreply, socket}

        {:error, _} ->
          socket =
            socket
            |> put_flash(:error, "Failed to send welcome email")

          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "Cannot send welcome email to this actor")}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", topic: topic}, socket) do
    actor = socket.assigns.selected_actor

    cond do
      is_nil(actor) ->
        {:noreply, socket}

      topic == "presences:portal_sessions:" <> actor.id ->
        sessions = Database.get_portal_sessions_for_actor(actor.id, socket.assigns.subject)
        {:noreply, assign(socket, sessions: sessions)}

      topic == "presences:actor_clients:" <> actor.id ->
        tokens = Database.get_client_tokens_for_actor(actor.id, socket.assigns.subject)
        {:noreply, assign(socket, tokens: tokens)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(:clear_welcome_email_sent, socket) do
    {:noreply, assign(socket, welcome_email_sent: false)}
  end

  defp validate_role_change(changeset, actor, socket) do
    new_type = get_change(changeset, :type)

    cond do
      # Prevent changing the last admin to account_user
      actor.type == :account_admin_user and new_type == :account_user and
          not other_enabled_admins_exist?(actor, socket.assigns.subject) ->
        changeset =
          changeset
          |> add_error(
            :type,
            "Cannot change role. At least one admin must remain in the account."
          )
          |> Map.put(:action, :validate)

        {:error, changeset}

      # Prevent promoting to admin when admin limit is reached
      actor.type != :account_admin_user and new_type == :account_admin_user and
          not Portal.Billing.can_create_admin_users?(
            Database.fetch_account(socket.assigns.account.id)
          ) ->
        changeset =
          changeset
          |> add_error(
            :type,
            "Admin user limit reached for your account"
          )
          |> Map.put(:action, :validate)

        {:error, changeset}

      # Role change allowed
      true ->
        :ok
    end
  end

  defp save_actor(changeset, socket) do
    case Database.update(changeset, socket.assigns.subject) do
      {:ok, actor} ->
        socket = apply_group_membership_changes(socket, actor, socket.assigns.subject)

        if socket.assigns.panel_view == :edit do
          identities = Database.get_identities_for_actor(actor.id, socket.assigns.subject)
          groups = Database.get_groups_for_actor(actor.id, socket.assigns.subject)

          {:noreply,
           socket
           |> put_flash(:success, "Actor updated successfully.")
           |> reload_live_table!("actors")
           |> assign(
             selected_actor: actor,
             panel_view: :detail,
             form: nil,
             identities: identities,
             groups: groups
           )}
        else
          {:noreply,
           socket
           |> put_flash(:success_inline, "Actor updated successfully")
           |> reload_live_table!("actors")
           |> push_patch(to: ~p"/#{socket.assigns.account}/actors/#{actor.id}")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_actors_update!(socket, list_opts) do
    with {:ok, actors, metadata} <- Database.list_actors(socket.assigns.subject, list_opts) do
      {:ok, assign(socket, actors: actors, actors_metadata: metadata)}
    end
  end

  defp subscribe_portal_sessions(socket, %{type: :service_account}), do: socket

  defp subscribe_portal_sessions(socket, actor) do
    if socket.assigns.portal_sessions_subscribed_actor_id != actor.id do
      if prev_id = socket.assigns.portal_sessions_subscribed_actor_id do
        Presence.PortalSessions.unsubscribe(prev_id)
      end

      Presence.PortalSessions.subscribe(actor.id)
      assign(socket, portal_sessions_subscribed_actor_id: actor.id)
    else
      socket
    end
  end

  defp unsubscribe_portal_sessions(socket) do
    if id = socket.assigns[:portal_sessions_subscribed_actor_id] do
      Presence.PortalSessions.unsubscribe(id)
      assign(socket, portal_sessions_subscribed_actor_id: nil)
    else
      socket
    end
  end

  defp subscribe_client_tokens(socket, actor) do
    if socket.assigns.client_tokens_subscribed_actor_id != actor.id do
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
    if id = socket.assigns[:client_tokens_subscribed_actor_id] do
      Presence.Clients.Actor.unsubscribe(id)
      assign(socket, client_tokens_subscribed_actor_id: nil)
    else
      socket
    end
  end

  defp maybe_update_actor_assign(socket, id, updated_actor) do
    socket =
      if Map.get(socket.assigns, :actor) && socket.assigns.actor.id == id do
        assign(socket, actor: updated_actor)
      else
        socket
      end

    if Map.get(socket.assigns, :selected_actor) && socket.assigns.selected_actor.id == id do
      assign(socket, selected_actor: updated_actor)
    else
      socket
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.page_header>
        <:icon>
          <.icon name="remix-user-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Actors</:title>
        <:description>
          All users in this account.
        </:description>
        <:action>
          <.docs_action path="/deploy/users" />
        </:action>
        <:action>
          <.button style="primary" icon="remix-add-line" phx-click="open_new_actor_panel">
            New Actor
          </.button>
        </:action>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="actors"
          rows={@actors}
          row_id={&"actor-#{&1.id}"}
          row_click={fn actor -> ~p"/#{@account}/actors/#{actor.id}?#{@query_params}" end}
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
          <:col :let={actor} field={{:actors, :email}} label="email" class="w-72">
            <span class="text-[var(--text-secondary)] block truncate" title={actor.email}>
              {actor.email || "-"}
            </span>
          </:col>
          <:col :let={actor} label="status" class="w-32">
            <.status_badge status={if is_nil(actor.disabled_at), do: :active, else: :disabled} />
          </:col>
          <:empty>
            <span class="text-sm text-[var(--text-tertiary)]">No actors to display.</span>
          </:empty>
        </.live_table>
      </div>

      <.actor_panel
        account={@account}
        actor={@selected_actor}
        active_tab={@active_tab}
        identities={@identities}
        groups={@groups}
        tokens={@tokens}
        sessions={@sessions}
        created_token={@created_token}
        query_params={@query_params}
        subject={@subject}
        panel_view={@panel_view}
        form={@form}
        is_last_admin={@is_last_admin}
        confirm_disable_actor={@confirm_disable_actor}
        confirm_delete_actor={@confirm_delete_actor}
        confirm_delete_identity_id={@confirm_delete_identity_id}
        confirm_delete_token_id={@confirm_delete_token_id}
        confirm_delete_session_id={@confirm_delete_session_id}
        welcome_email_sent={@welcome_email_sent}
        adding_token={@adding_token}
        token_expiration={@token_expiration}
        creating_actor={@creating_actor}
        new_actor_type={@new_actor_type}
        pending_group_additions={@pending_group_additions}
        pending_group_removals={@pending_group_removals}
        group_search_results={@group_search_results}
      />
    </div>

    <!-- Add Actor - Type Selection Modal -->
    <.modal
      :if={@live_action == :add}
      id="add-actor-modal"
      on_close="close_modal"
    >
      <:title>Add Actor</:title>
      <:body>
        <h3 class="text-lg font-semibold mb-4">Select type</h3>
        <div class="grid gap-4 md:grid-cols-2">
          <button
            type="button"
            phx-click="select_type"
            phx-value-type="user"
            class="flex flex-col items-center justify-center p-6 border-2 border-neutral-200 rounded-md hover:border-accent-500 hover:bg-neutral-50 transition-all"
          >
            <.icon name="remix-user-line" class="w-12 h-12 mb-3 text-neutral-600" />
            <span class="text-lg font-semibold text-neutral-900">User</span>
            <span class="text-sm text-neutral-600 mt-2 text-center">
              User accounts can sign in to the Firezone Client apps or to the admin portal
            </span>
          </button>

          <button
            type="button"
            phx-click="select_type"
            phx-value-type="service_account"
            class="flex flex-col items-center justify-center p-6 border-2 border-neutral-200 rounded-md hover:border-accent-500 hover:bg-neutral-50 transition-all"
          >
            <.icon name="remix-server-line" class="w-12 h-12 mb-3 text-neutral-600" />
            <span class="text-lg font-semibold text-neutral-900">Service account</span>
            <span class="text-sm text-neutral-600 mt-2 text-center">
              Service accounts are used to authenticate headless Clients
            </span>
          </button>
        </div>
      </:body>
    </.modal>

    <!-- Add User Modal -->
    <.modal
      :if={@live_action == :add_user}
      id="add-user-modal"
      on_close="close_modal"
      confirm_disabled={not @form.source.valid?}
    >
      <:title>Add User</:title>
      <:body>
        <.flash kind={:error_inline} style="inline" flash={@flash} />
        <.form id="user-form" for={@form} phx-change="validate" phx-submit="create_user">
          <div class="space-y-6">
            <.input
              field={@form[:name]}
              label="Name"
              placeholder="Enter user name"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />

            <.input
              field={@form[:email]}
              label="Email"
              type="email"
              placeholder="user@example.com"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />

            <.input
              field={@form[:type]}
              label="Role"
              type="select"
              options={[
                {"User", :account_user},
                {"Admin", :account_admin_user}
              ]}
              required
            />

            <div
              :if={@form[:type].value != :service_account}
              id="allow-email-otp-checkbox"
              phx-update="ignore"
            >
              <.input
                field={@form[:allow_email_otp_sign_in]}
                label="Allow Email OTP Sign In"
                type="checkbox"
              />
            </div>
          </div>
        </.form>
      </:body>
      <:confirm_button form="user-form" type="submit">Create</:confirm_button>
    </.modal>

    <!-- Add Service Account Modal -->
    <.modal
      :if={@live_action == :add_service_account}
      id="add-service-account-modal"
      on_close="close_modal"
      confirm_disabled={not @form.source.valid?}
    >
      <:title>Add Service Account</:title>
      <:body>
        <.flash kind={:error_inline} style="inline" flash={@flash} />
        <.form
          id="service-account-form"
          for={@form}
          phx-change="validate"
          phx-submit="create_service_account"
        >
          <div class="space-y-6">
            <.input
              field={@form[:name]}
              label="Name"
              placeholder="E.g. GitHub CI"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />

            <div>
              <label class="block text-sm font-medium text-neutral-700 mb-2">
                Token expiration
              </label>
              <input
                type="date"
                name="token_expiration"
                value={@token_expiration}
                class="block w-full rounded-md border-neutral-300 focus:border-accent-400 focus:ring-3 focus:ring-accent-200/50"
              />
            </div>
          </div>
        </.form>
      </:body>
      <:confirm_button form="service-account-form" type="submit">Create</:confirm_button>
    </.modal>

    <!-- Add Token Modal -->
    <.modal
      :if={@live_action == :add_token}
      id="add-token-modal"
      on_close="close_modal"
      confirm_disabled={@token_expiration == ""}
    >
      <:title>Add Token for {@actor.name}</:title>
      <:body>
        <form id="token-form" phx-change="validate_token" phx-submit="create_token">
          <div class="space-y-6">
            <div>
              <label class="block text-sm font-medium text-neutral-700 mb-2">
                Token expiration
              </label>
              <input
                type="date"
                name="token_expiration"
                value={@token_expiration}
                class="block w-full rounded-md border-neutral-300 focus:border-accent-400 focus:ring-3 focus:ring-accent-200/50"
                required
              />
            </div>
          </div>
        </form>
      </:body>
      <:confirm_button form="token-form" type="submit">Create Token</:confirm_button>
    </.modal>
    """
  end

  # Helper Components
  defp actor_type_icon(assigns) do
    assigns = assign_new(assigns, :class, fn -> "w-6 h-6" end)

    ~H"""
    <%= case @actor.type do %>
      <% :service_account -> %>
        <.icon name="remix-server-line" class={@class} />
      <% :account_admin_user -> %>
        <.icon name="remix-shield-check-line" class={@class} />
      <% _ -> %>
        <.icon name="remix-user-line" class={@class} />
    <% end %>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :active_tab, :string, default: "identities"
  attr :identities, :list, default: []
  attr :groups, :list, default: []
  attr :tokens, :list, default: []
  attr :sessions, :list, default: []
  attr :created_token, :string, default: nil
  attr :query_params, :map, default: %{}
  attr :subject, :any, required: true
  attr :panel_view, :atom, default: :detail
  attr :form, :any, default: nil
  attr :is_last_admin, :boolean, default: false
  attr :confirm_disable_actor, :boolean, default: false
  attr :confirm_delete_actor, :boolean, default: false
  attr :confirm_delete_identity_id, :string, default: nil
  attr :confirm_delete_token_id, :string, default: nil
  attr :confirm_delete_session_id, :string, default: nil
  attr :welcome_email_sent, :boolean, default: false
  attr :adding_token, :boolean, default: false
  attr :token_expiration, :string, default: ""
  attr :creating_actor, :boolean, default: false
  attr :new_actor_type, :atom, default: nil
  attr :pending_group_additions, :list, default: []
  attr :pending_group_removals, :list, default: []
  attr :group_search_results, :list, default: nil

  defp actor_panel(assigns) do
    ~H"""
    <div
      id="actor-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@actor || @creating_actor, do: "translate-x-0", else: "translate-x-full")
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <div :if={@actor} class="flex flex-col h-full overflow-hidden">
        <%!-- Panel header --%>
        <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
          <div class="flex items-start justify-between gap-3">
            <div class="flex items-center gap-3 min-w-0">
              <.actor_type_icon_circle actor={@actor} />
              <div class="min-w-0">
                <h2 class="text-sm font-semibold text-[var(--text-primary)] truncate">
                  {@actor.name}
                </h2>
                <p :if={@actor.email} class="text-xs text-[var(--text-tertiary)] truncate">
                  {@actor.email}
                </p>
              </div>
            </div>
            <div class="flex items-center gap-1.5 shrink-0">
              <button
                :if={@panel_view == :detail}
                type="button"
                phx-click="open_actor_edit_form"
                class="flex items-center gap-1 px-2.5 py-1.5 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
              >
                <.icon name="remix-pencil-line" class="w-3.5 h-3.5" /> Edit
              </button>
              <button
                phx-click="close_panel"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="remix-close-line" class="w-4 h-4" />
              </button>
            </div>
          </div>
          <%!-- Stat strip --%>
          <div class="flex items-center gap-5 mt-3 pt-3 border-t border-[var(--border)]">
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Status
              </span>
              <.status_badge status={if is_nil(@actor.disabled_at), do: :active, else: :disabled} />
            </div>
            <div class="w-px h-3.5 bg-[var(--border-strong)]"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Groups
              </span>
              <span class="text-xs font-semibold tabular-nums text-[var(--text-primary)]">
                {length(@groups)}
              </span>
            </div>
            <div class="w-px h-3.5 bg-[var(--border-strong)]"></div>
            <div class="flex items-center gap-1.5">
              <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                {if @actor.type == :service_account, do: "Tokens", else: "Clients"}
              </span>
              <span class="text-xs font-semibold tabular-nums text-[var(--text-primary)]">
                {length(@tokens)}
              </span>
            </div>
          </div>
        </div>
        <%!-- Panel body --%>
        <div :if={@panel_view == :detail} class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
          <%!-- Left: Tabs --%>
          <div class="flex-1 flex flex-col overflow-hidden">
            <%!-- Tab bar --%>
            <div class="flex shrink-0 border-b border-[var(--border)] bg-[var(--surface-raised)] overflow-x-auto items-center">
              <div class="flex flex-1 px-1 gap-0.5">
                <%= if @actor.type != :service_account do %>
                  <button
                    type="button"
                    phx-click="change_tab"
                    phx-value-tab="identities"
                    class={[
                      "px-3 py-2.5 text-xs font-medium whitespace-nowrap border-b-2 transition-colors",
                      if(@active_tab == "identities",
                        do: "border-[var(--brand)] text-[var(--brand)]",
                        else:
                          "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                      )
                    ]}
                  >
                    <span class="flex items-center gap-1.5">
                      <.icon name="remix-id-card-line" class="w-3.5 h-3.5" /> External Identities
                    </span>
                  </button>
                  <button
                    type="button"
                    phx-click="change_tab"
                    phx-value-tab="client_sessions"
                    class={[
                      "px-3 py-2.5 text-xs font-medium whitespace-nowrap border-b-2 transition-colors",
                      if(@active_tab == "client_sessions",
                        do: "border-[var(--brand)] text-[var(--brand)]",
                        else:
                          "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                      )
                    ]}
                  >
                    <span class="flex items-center gap-1.5">
                      <.icon name="remix-smartphone-line" class="w-3.5 h-3.5" /> Client Sessions
                    </span>
                  </button>
                  <button
                    type="button"
                    phx-click="change_tab"
                    phx-value-tab="portal_sessions"
                    class={[
                      "px-3 py-2.5 text-xs font-medium whitespace-nowrap border-b-2 transition-colors",
                      if(@active_tab == "portal_sessions",
                        do: "border-[var(--brand)] text-[var(--brand)]",
                        else:
                          "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                      )
                    ]}
                  >
                    <span class="flex items-center gap-1.5">
                      <.icon name="remix-computer-line" class="w-3.5 h-3.5" /> Portal Sessions
                    </span>
                  </button>
                <% else %>
                  <button
                    type="button"
                    phx-click="change_tab"
                    phx-value-tab="tokens"
                    class={[
                      "px-3 py-2.5 text-xs font-medium whitespace-nowrap border-b-2 transition-colors",
                      if(@active_tab == "tokens",
                        do: "border-[var(--brand)] text-[var(--brand)]",
                        else:
                          "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                      )
                    ]}
                  >
                    <span class="flex items-center gap-1.5">
                      <.icon name="remix-key-line" class="w-3.5 h-3.5" /> Tokens
                    </span>
                  </button>
                <% end %>
                <button
                  type="button"
                  phx-click="change_tab"
                  phx-value-tab="groups"
                  class={[
                    "px-3 py-2.5 text-xs font-medium whitespace-nowrap border-b-2 transition-colors",
                    if(@active_tab == "groups",
                      do: "border-[var(--brand)] text-[var(--brand)]",
                      else:
                        "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                    )
                  ]}
                >
                  <span class="flex items-center gap-1.5">
                    <.icon name="remix-team-line" class="w-3.5 h-3.5" /> Groups
                  </span>
                </button>
              </div>
              <div class="shrink-0 px-2">
                <button
                  :if={
                    @actor.type == :service_account and @active_tab == "tokens" and not @adding_token
                  }
                  type="button"
                  phx-click="open_add_token_form"
                  class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  <.icon name="remix-add-line" class="w-3 h-3" /> Add Token
                </button>
              </div>
            </div>
            <%!-- Tab content --%>
            <div class="flex-1 overflow-y-auto">
              <%!-- External Identities tab --%>
              <div :if={@actor.type != :service_account and @active_tab == "identities"}>
                <div
                  :if={@identities == []}
                  class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
                >
                  No identity provider accounts linked.
                </div>
                <ul :if={@identities != []}>
                  <li
                    :for={identity <- @identities}
                    class="border-b border-[var(--border)] group/item"
                  >
                    <div
                      :if={@confirm_delete_identity_id == identity.id}
                      class="flex items-center justify-between gap-2 px-5 py-2.5 bg-[var(--surface-raised)]"
                    >
                      <span class="text-xs text-[var(--text-secondary)] truncate">
                        Delete this identity?
                        <span class="block text-[var(--text-tertiary)]">
                          This cannot be undone.
                        </span>
                      </span>
                      <div class="flex items-center gap-1.5 shrink-0">
                        <button
                          type="button"
                          phx-click="cancel_delete_identity"
                          class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                        >
                          Cancel
                        </button>
                        <button
                          type="button"
                          phx-click="delete_identity"
                          phx-value-id={identity.id}
                          class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
                        >
                          Delete
                        </button>
                      </div>
                    </div>
                    <details :if={@confirm_delete_identity_id != identity.id} class="group/details">
                      <summary class="flex items-center gap-3 px-5 py-3 pr-4 hover:bg-[var(--surface-raised)] transition-colors cursor-pointer list-none">
                        <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
                          <.provider_icon
                            type={provider_type_from_issuer(identity.issuer)}
                            class="w-4 h-4"
                          />
                        </div>
                        <div class="flex-1 min-w-0">
                          <p
                            class="text-sm font-medium text-[var(--text-primary)] truncate"
                            title={identity.issuer}
                          >
                            {identity.issuer}
                          </p>
                          <div class="flex items-center gap-3 mt-0.5">
                            <span
                              :if={identity.email}
                              class="text-xs text-[var(--text-tertiary)] truncate"
                            >
                              {identity.email}
                            </span>
                            <span class="font-mono text-xs text-[var(--text-tertiary)] truncate">
                              {extract_idp_id(identity.idp_id)}
                            </span>
                          </div>
                        </div>
                        <div class="flex items-center gap-1 shrink-0">
                          <button
                            type="button"
                            phx-click="confirm_delete_identity"
                            phx-value-id={identity.id}
                            class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--status-error)] hover:bg-[var(--surface)] transition-colors opacity-0 group-hover/item:opacity-100"
                            title="Delete identity"
                          >
                            <.icon name="remix-delete-bin-line" class="w-3.5 h-3.5" />
                          </button>
                          <.icon
                            name="remix-arrow-right-s-line"
                            class="w-4 h-4 text-[var(--text-muted)] transition-transform group-open/details:rotate-90"
                          />
                        </div>
                      </summary>
                      <div class="pl-[3.75rem] pr-5 pb-4 pt-1 bg-[var(--surface-raised)]/50">
                        <dl class="grid grid-cols-2 gap-x-6 gap-y-3">
                          <div :if={identity.directory_name}>
                            <dt class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                              Directory
                            </dt>
                            <dd
                              class="text-xs text-[var(--text-primary)] truncate mt-0.5"
                              title={identity.directory_name}
                            >
                              {identity.directory_name}
                            </dd>
                          </div>
                          <div>
                            <dt class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                              IDP ID
                            </dt>
                            <dd
                              class="font-mono text-xs text-[var(--text-primary)] truncate mt-0.5"
                              title={identity.idp_id}
                            >
                              {extract_idp_id(identity.idp_id)}
                            </dd>
                          </div>
                          <div :if={identity.email}>
                            <dt class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                              Email
                            </dt>
                            <dd class="text-xs text-[var(--text-primary)] truncate mt-0.5">
                              {identity.email}
                            </dd>
                          </div>
                          <div :if={identity.name}>
                            <dt class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                              Name
                            </dt>
                            <dd class="text-xs text-[var(--text-primary)] truncate mt-0.5">
                              {identity.name}
                            </dd>
                          </div>
                          <div :if={identity.given_name}>
                            <dt class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                              Given Name
                            </dt>
                            <dd class="text-xs text-[var(--text-primary)] truncate mt-0.5">
                              {identity.given_name}
                            </dd>
                          </div>
                          <div :if={identity.family_name}>
                            <dt class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                              Family Name
                            </dt>
                            <dd class="text-xs text-[var(--text-primary)] truncate mt-0.5">
                              {identity.family_name}
                            </dd>
                          </div>
                          <div :if={identity.middle_name}>
                            <dt class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                              Middle Name
                            </dt>
                            <dd class="text-xs text-[var(--text-primary)] truncate mt-0.5">
                              {identity.middle_name}
                            </dd>
                          </div>
                          <div :if={identity.nickname}>
                            <dt class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                              Nickname
                            </dt>
                            <dd class="text-xs text-[var(--text-primary)] truncate mt-0.5">
                              {identity.nickname}
                            </dd>
                          </div>
                          <div :if={identity.preferred_username}>
                            <dt class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                              Preferred Username
                            </dt>
                            <dd class="text-xs text-[var(--text-primary)] truncate mt-0.5">
                              {identity.preferred_username}
                            </dd>
                          </div>
                          <div :if={identity.last_synced_at}>
                            <dt class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                              Last Synced
                            </dt>
                            <dd class="text-xs text-[var(--text-secondary)] mt-0.5">
                              <.relative_datetime datetime={identity.last_synced_at} />
                            </dd>
                          </div>
                        </dl>
                      </div>
                    </details>
                  </li>
                </ul>
              </div>
              <%!-- Client Sessions tab --%>
              <div :if={@actor.type != :service_account and @active_tab == "client_sessions"}>
                <div
                  :if={@tokens == []}
                  class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
                >
                  No active client sessions.
                </div>
                <ul :if={@tokens != []}>
                  <li
                    :for={token <- @tokens}
                    class="border-b border-[var(--border)] group/item"
                  >
                    <div
                      :if={@confirm_delete_token_id == token.id}
                      class="flex items-center justify-between gap-2 px-5 py-2.5 bg-[var(--surface-raised)]"
                    >
                      <span class="text-xs text-[var(--text-secondary)] truncate">
                        Revoke this session?
                        <span class="block text-[var(--text-tertiary)]">This cannot be undone.</span>
                      </span>
                      <div class="flex items-center gap-1.5 shrink-0">
                        <button
                          type="button"
                          phx-click="cancel_delete_token"
                          class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                        >
                          Cancel
                        </button>
                        <button
                          type="button"
                          phx-click="delete_token"
                          phx-value-id={token.id}
                          class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
                        >
                          Revoke
                        </button>
                      </div>
                    </div>
                    <div
                      :if={@confirm_delete_token_id != token.id}
                      class="flex items-center gap-3 pr-4 hover:bg-[var(--surface-raised)] transition-colors"
                    >
                      <div class="flex items-center gap-3 px-5 py-3 flex-1 min-w-0">
                        <.ping_icon
                          color={if token.online?, do: "success", else: "danger"}
                          title={if token.online?, do: "Online", else: "Offline"}
                        />
                        <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
                          <.icon
                            name={
                              client_os_icon_name(
                                token.latest_session && token.latest_session.user_agent
                              )
                            }
                            class="w-4 h-4 text-[var(--text-secondary)]"
                          />
                        </div>
                        <div class="flex-1 min-w-0">
                          <p class="text-sm font-medium text-[var(--text-primary)]">
                            {if token.online?, do: "Online", else: "Offline"}
                          </p>
                          <div class="flex items-center gap-3 mt-0.5 text-xs text-[var(--text-tertiary)]">
                            <span>
                              Connected
                              <.relative_datetime datetime={
                                token.latest_session && token.latest_session.inserted_at
                              } />
                            </span>
                            <span :if={
                              token_location(token) ||
                                (token.latest_session && token.latest_session.remote_ip)
                            }>
                              Location: {token_location(token) ||
                                (token.latest_session && token.latest_session.remote_ip)}
                            </span>
                          </div>
                        </div>
                      </div>
                      <button
                        type="button"
                        phx-click="confirm_delete_token"
                        phx-value-id={token.id}
                        class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--status-error)] hover:bg-[var(--surface)] transition-colors opacity-0 group-hover/item:opacity-100"
                        title="Revoke session"
                      >
                        <.icon name="remix-delete-bin-line" class="w-3.5 h-3.5" />
                      </button>
                    </div>
                  </li>
                </ul>
              </div>
              <%!-- Portal Sessions tab --%>
              <div :if={@actor.type != :service_account and @active_tab == "portal_sessions"}>
                <div
                  :if={@sessions == []}
                  class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
                >
                  No active portal sessions.
                </div>
                <ul :if={@sessions != []}>
                  <li
                    :for={session <- @sessions}
                    class="border-b border-[var(--border)] group/item"
                  >
                    <div
                      :if={@confirm_delete_session_id == session.id}
                      class="flex items-center justify-between gap-2 px-5 py-2.5 bg-[var(--surface-raised)]"
                    >
                      <span class="text-xs text-[var(--text-secondary)] truncate">
                        Revoke this session?
                        <span class="block text-[var(--text-tertiary)]">This cannot be undone.</span>
                      </span>
                      <div class="flex items-center gap-1.5 shrink-0">
                        <button
                          type="button"
                          phx-click="cancel_delete_session"
                          class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                        >
                          Cancel
                        </button>
                        <button
                          type="button"
                          phx-click="delete_session"
                          phx-value-id={session.id}
                          class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
                        >
                          Revoke
                        </button>
                      </div>
                    </div>
                    <div
                      :if={@confirm_delete_session_id != session.id}
                      class="flex items-center gap-3 pr-4 hover:bg-[var(--surface-raised)] transition-colors"
                    >
                      <div class="flex items-center gap-3 px-5 py-3 flex-1 min-w-0">
                        <.ping_icon
                          color={if session.online?, do: "success", else: "danger"}
                          title={if session.online?, do: "Online", else: "Offline"}
                        />
                        <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
                          <.icon
                            name={session_user_agent_icon(session.user_agent)}
                            class="w-4 h-4 text-[var(--text-secondary)]"
                          />
                        </div>
                        <div class="flex-1 min-w-0">
                          <p class="text-sm font-medium text-[var(--text-primary)]">
                            {if session.online?, do: "Online", else: "Offline"}
                          </p>
                          <div class="flex items-center gap-3 mt-0.5 text-xs text-[var(--text-tertiary)]">
                            <span>
                              Signed in <.relative_datetime datetime={session.inserted_at} />
                            </span>
                            <span :if={session_location(session) || session.remote_ip}>
                              Location: {session_location(session) || session.remote_ip}
                            </span>
                          </div>
                        </div>
                      </div>
                      <button
                        type="button"
                        phx-click="confirm_delete_session"
                        phx-value-id={session.id}
                        class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--status-error)] hover:bg-[var(--surface)] transition-colors opacity-0 group-hover/item:opacity-100"
                        title="Revoke session"
                      >
                        <.icon name="remix-delete-bin-line" class="w-3.5 h-3.5" />
                      </button>
                    </div>
                  </li>
                </ul>
              </div>
              <%!-- Tokens tab (Service Accounts) --%>
              <div :if={@actor.type == :service_account and @active_tab == "tokens"}>
                <%!-- Created token view --%>
                <div :if={@created_token} class="px-5 py-5 space-y-4">
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <p class="text-sm font-semibold text-[var(--text-primary)]">Token Created</p>
                      <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                        Save this token — you won't be able to see it again.
                      </p>
                    </div>
                    <button
                      type="button"
                      phx-click="dismiss_created_token"
                      class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors shrink-0"
                      title="Dismiss"
                    >
                      <.icon name="remix-close-line" class="w-4 h-4" />
                    </button>
                  </div>
                  <div id="tab-token-copy" class="relative" phx-hook="CopyClipboard">
                    <code
                      id="tab-token-copy-code"
                      class="block font-mono text-[11px] break-all bg-[var(--surface-raised)] border border-[var(--border)] rounded px-3 py-2.5 pr-9 text-[var(--text-primary)]"
                    >
                      {@created_token}
                    </code>
                    <button
                      type="button"
                      data-copy-to-clipboard-target="tab-token-copy-code"
                      data-copy-to-clipboard-content-type="innerHTML"
                      data-copy-to-clipboard-html-entities="true"
                      class="absolute top-2 right-2 text-[var(--text-tertiary)] hover:text-[var(--text-primary)] transition-colors"
                      title="Copy token"
                    >
                      <.icon name="remix-clipboard-line" class="w-4 h-4" />
                    </button>
                  </div>
                </div>
                <%!-- Add token form --%>
                <div :if={is_nil(@created_token) and @adding_token} class="px-5 py-4 space-y-4">
                  <p class="text-sm font-medium text-[var(--text-primary)]">New Token</p>
                  <form phx-change="validate_token" phx-submit="create_token" class="space-y-4">
                    <div>
                      <label class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5">
                        Token expiration
                      </label>
                      <input
                        type="date"
                        name="token_expiration"
                        value={@token_expiration}
                        class="block w-full rounded-md border-neutral-300 focus:border-accent-400 focus:ring-3 focus:ring-accent-200/50 text-sm"
                        required
                      />
                    </div>
                    <div class="flex items-center gap-2">
                      <button
                        type="button"
                        phx-click="cancel_add_token_form"
                        class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                      >
                        Cancel
                      </button>
                      <button
                        type="submit"
                        class="px-3 py-1.5 text-xs rounded-md font-medium bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] transition-colors"
                      >
                        Create Token
                      </button>
                    </div>
                  </form>
                </div>
                <%!-- Token list --%>
                <div :if={is_nil(@created_token) and not @adding_token}>
                  <div
                    :if={@tokens == []}
                    class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
                  >
                    No tokens. Add one to authenticate this service account.
                  </div>
                  <ul :if={@tokens != []}>
                    <li
                      :for={token <- @tokens}
                      class="border-b border-[var(--border)] group/item"
                    >
                      <div
                        :if={@confirm_delete_token_id == token.id}
                        class="flex items-center justify-between gap-2 px-5 py-2.5 bg-[var(--surface-raised)]"
                      >
                        <span class="text-xs text-[var(--text-secondary)] truncate">
                          Delete this token?
                          <span class="block text-[var(--text-tertiary)]">
                            This cannot be undone.
                          </span>
                        </span>
                        <div class="flex items-center gap-1.5 shrink-0">
                          <button
                            type="button"
                            phx-click="cancel_delete_token"
                            class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                          >
                            Cancel
                          </button>
                          <button
                            type="button"
                            phx-click="delete_token"
                            phx-value-id={token.id}
                            class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
                          >
                            Delete
                          </button>
                        </div>
                      </div>
                      <div
                        :if={@confirm_delete_token_id != token.id}
                        class="flex items-center gap-3 pr-4 hover:bg-[var(--surface-raised)] transition-colors"
                      >
                        <div class="flex items-center gap-3 px-5 py-3 flex-1 min-w-0">
                          <.ping_icon
                            color={if token.online?, do: "success", else: "danger"}
                            title={if token.online?, do: "Active", else: "Inactive"}
                          />
                          <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
                            <.icon name="remix-key-line" class="w-4 h-4 text-[var(--text-secondary)]" />
                          </div>
                          <div class="flex-1 min-w-0">
                            <p class="text-sm font-medium text-[var(--text-primary)]">
                              {if token.online?, do: "Active", else: "Inactive"}
                            </p>
                            <div class="flex items-center gap-3 mt-0.5 text-xs text-[var(--text-tertiary)]">
                              <span>
                                Last used:
                                <.relative_datetime datetime={
                                  token.latest_session && token.latest_session.inserted_at
                                } />
                              </span>
                              <span :if={token.expires_at}>
                                Expires: <.relative_datetime datetime={token.expires_at} />
                              </span>
                              <span :if={
                                token_location(token) ||
                                  (token.latest_session && token.latest_session.remote_ip)
                              }>
                                Location: {token_location(token) ||
                                  (token.latest_session && token.latest_session.remote_ip)}
                              </span>
                            </div>
                          </div>
                        </div>
                        <button
                          type="button"
                          phx-click="confirm_delete_token"
                          phx-value-id={token.id}
                          class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--status-error)] hover:bg-[var(--surface)] transition-colors opacity-0 group-hover/item:opacity-100"
                          title="Delete token"
                        >
                          <.icon name="remix-delete-bin-line" class="w-3.5 h-3.5" />
                        </button>
                      </div>
                    </li>
                  </ul>
                </div>
              </div>
              <%!-- Groups tab --%>
              <div :if={@active_tab == "groups"}>
                <div
                  :if={@groups == []}
                  class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
                >
                  Not a member of any groups.
                </div>
                <ul :if={@groups != []}>
                  <li
                    :for={group <- @groups}
                    class="border-b border-[var(--border)] transition-colors"
                  >
                    <.link
                      navigate={~p"/#{@account}/groups/#{group.id}"}
                      class="flex items-center gap-3 px-5 py-3 flex-1 min-w-0 hover:bg-[var(--surface-raised)] group/item"
                    >
                      <div class="flex items-center justify-center w-7 h-7 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] shrink-0">
                        <.provider_icon type={provider_type_from_group(group)} class="w-4 h-4" />
                      </div>
                      <span class="flex-1 text-sm font-medium text-[var(--text-primary)] group-hover/item:text-[var(--brand)] transition-colors truncate">
                        {group.name}
                      </span>
                      <.icon
                        name="remix-arrow-right-s-line"
                        class="w-4 h-4 text-[var(--text-muted)] shrink-0"
                      />
                    </.link>
                  </li>
                </ul>
              </div>
            </div>
          </div>
          <%!-- Right: Details --%>
          <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
            <%!-- Details --%>
            <section>
              <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
                Details
              </h3>
              <dl class="space-y-3">
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Actor ID</dt>
                  <dd class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                    {@actor.id}
                  </dd>
                </div>
                <div :if={@actor.email}>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Email</dt>
                  <dd class="text-xs text-[var(--text-primary)] break-all">{@actor.email}</dd>
                </div>
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Created</dt>
                  <dd class="text-xs text-[var(--text-secondary)]">
                    <.relative_datetime datetime={@actor.inserted_at} />
                  </dd>
                </div>
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Updated</dt>
                  <dd class="text-xs text-[var(--text-secondary)]">
                    <.relative_datetime datetime={@actor.updated_at} />
                  </dd>
                </div>
                <div :if={@actor.type != :service_account}>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Email OTP Sign In</dt>
                  <dd>
                    <span class={[
                      "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[11px] font-medium",
                      if(@actor.allow_email_otp_sign_in,
                        do: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400",
                        else: "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"
                      )
                    ]}>
                      <.icon
                        name={
                          if @actor.allow_email_otp_sign_in,
                            do: "remix-checkbox-circle-line",
                            else: "remix-prohibited-line"
                        }
                        class="w-3 h-3"
                      />
                      {if @actor.allow_email_otp_sign_in, do: "Allowed", else: "Not Allowed"}
                    </span>
                  </dd>
                </div>
                <div>
                  <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Role</dt>
                  <dd><.actor_type_badge actor={@actor} /></dd>
                </div>
              </dl>
            </section>
            <%!-- Actions --%>
            <div class="border-t border-[var(--border)]"></div>
            <section>
              <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
                Actions
              </h3>
              <div class="space-y-1.5">
                <button
                  :if={
                    @actor.type in [:account_user, :account_admin_user] and not is_nil(@actor.email) and
                      not @welcome_email_sent
                  }
                  type="button"
                  phx-click="send_welcome_email"
                  phx-value-id={@actor.id}
                  class="flex items-center gap-2 w-full px-3 py-2 rounded text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="remix-mail-line" class="w-3.5 h-3.5" /> Send Welcome Email
                </button>
                <div
                  :if={
                    @actor.type in [:account_user, :account_admin_user] and not is_nil(@actor.email) and
                      @welcome_email_sent
                  }
                  class="flex items-center gap-2 w-full px-3 py-2 rounded text-xs text-green-600 bg-green-50 dark:text-green-400 dark:bg-green-900/20"
                >
                  <.icon name="remix-checkbox-circle-line" class="w-3.5 h-3.5" />
                  Email sent to {@actor.email}
                </div>
                <button
                  :if={
                    is_nil(@actor.disabled_at) and @actor.id != @subject.actor.id and
                      not @confirm_disable_actor
                  }
                  type="button"
                  phx-click="confirm_disable_actor"
                  class="flex items-center gap-2 w-full px-3 py-2 rounded text-xs text-[var(--status-warning)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="remix-pause-line" class="w-3.5 h-3.5" /> Disable
                </button>
                <div
                  :if={
                    is_nil(@actor.disabled_at) and @actor.id != @subject.actor.id and
                      @confirm_disable_actor
                  }
                  class="px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)]"
                >
                  <p class="text-xs font-medium text-[var(--text-primary)] mb-1">
                    Disable this actor?
                  </p>
                  <p class="text-xs text-[var(--text-secondary)] mb-3">
                    All active sessions will be immediately revoked.
                  </p>
                  <div class="flex items-center gap-1.5">
                    <button
                      type="button"
                      phx-click="cancel_disable_actor"
                      class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                    >
                      Cancel
                    </button>
                    <button
                      type="button"
                      phx-click="disable"
                      phx-value-id={@actor.id}
                      class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors font-medium"
                    >
                      Disable
                    </button>
                  </div>
                </div>
                <button
                  :if={not is_nil(@actor.disabled_at)}
                  type="button"
                  phx-click="enable"
                  phx-value-id={@actor.id}
                  class="flex items-center gap-2 w-full px-3 py-2 rounded text-xs text-[var(--status-active)] hover:bg-[var(--surface-raised)] transition-colors"
                >
                  <.icon name="remix-play-line" class="w-3.5 h-3.5" /> Enable
                </button>
              </div>
            </section>
            <%!-- Danger Zone --%>
            <div :if={@actor.id != @subject.actor.id} class="border-t border-[var(--border)]"></div>
            <section :if={@actor.id != @subject.actor.id}>
              <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--status-error)]/60 mb-3">
                Danger Zone
              </h3>
              <button
                :if={not @confirm_delete_actor}
                type="button"
                phx-click="confirm_delete_actor"
                class="w-full text-left px-3 py-2 rounded border border-[var(--status-error)]/20 text-xs text-[var(--status-error)] hover:bg-[var(--status-error-bg)] transition-colors"
              >
                Delete actor
              </button>
              <div
                :if={@confirm_delete_actor}
                class="px-3 py-2.5 rounded border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
              >
                <p class="text-xs font-medium text-[var(--status-error)] mb-1">
                  Delete this actor?
                </p>
                <p class="text-xs text-[var(--status-error)]/70 mb-3">
                  All active sessions will be immediately revoked and this cannot be undone.
                </p>
                <div class="flex items-center gap-1.5">
                  <button
                    type="button"
                    phx-click="cancel_delete_actor"
                    class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    type="button"
                    phx-click="delete"
                    phx-value-id={@actor.id}
                    class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </section>
          </div>
        </div>
        <%!-- Edit form --%>
        <.form
          :if={@panel_view == :edit}
          for={@form}
          phx-change="validate"
          phx-submit="save"
          class="flex flex-col flex-1 min-h-0 overflow-hidden"
        >
          <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
            <.input
              field={@form[:name]}
              label="Name"
              placeholder="Enter actor name"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />
            <.input
              :if={@actor.type != :service_account}
              field={@form[:email]}
              label="Email"
              type="email"
              placeholder="user@example.com"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />
            <div :if={@actor.type != :service_account}>
              <label class="block text-sm font-medium text-[var(--text-secondary)] mb-2">Role</label>
              <div class="grid grid-cols-2 gap-2">
                <div>
                  <.input
                    id={"#{@form[:type].id}--user"}
                    type="radio_button_group"
                    field={@form[:type]}
                    value="account_user"
                    checked={@form[:type].value in [:account_user, "account_user"]}
                    disabled={false}
                  />
                  <label
                    for={"#{@form[:type].id}--user"}
                    class="flex flex-col gap-1 p-3 rounded-lg border border-[var(--border)] cursor-pointer peer-checked:border-[var(--brand)] peer-checked:bg-[var(--surface-raised)] hover:bg-[var(--surface-raised)] transition-colors"
                  >
                    <span class="flex items-center gap-1.5 text-xs font-semibold text-[var(--text-primary)]">
                      <.icon name="remix-user-line" class="w-3.5 h-3.5" /> User
                    </span>
                    <span class="text-[11px] text-[var(--text-tertiary)]">
                      Sign in to Client apps and portal
                    </span>
                  </label>
                </div>
                <div>
                  <.input
                    id={"#{@form[:type].id}--admin"}
                    type="radio_button_group"
                    field={@form[:type]}
                    value="account_admin_user"
                    checked={@form[:type].value in [:account_admin_user, "account_admin_user"]}
                    disabled={@is_last_admin}
                  />
                  <label
                    for={"#{@form[:type].id}--admin"}
                    class={[
                      "flex flex-col gap-1 p-3 rounded-lg border border-[var(--border)] peer-checked:border-[var(--brand)] peer-checked:bg-[var(--surface-raised)] transition-colors",
                      if(@is_last_admin,
                        do: "opacity-50 cursor-not-allowed",
                        else: "cursor-pointer hover:bg-[var(--surface-raised)]"
                      )
                    ]}
                  >
                    <span class="flex items-center gap-1.5 text-xs font-semibold text-[var(--text-primary)]">
                      <.icon name="remix-shield-check-line" class="w-3.5 h-3.5" /> Admin
                    </span>
                    <span class="text-[11px] text-[var(--text-tertiary)]">
                      Full access to manage this account
                    </span>
                  </label>
                </div>
              </div>
              <p :if={@is_last_admin} class="mt-1 text-xs text-orange-600">
                Cannot change role. At least one admin must remain in the account.
              </p>
            </div>
            <div
              :if={@actor.type != :service_account}
              id="edit-allow-email-otp-checkbox"
              phx-update="ignore"
            >
              <div class="flex items-center justify-between py-1">
                <div>
                  <p class="text-sm font-medium text-[var(--text-secondary)]">Email OTP Sign In</p>
                  <p class="text-[11px] text-[var(--text-tertiary)]">
                    Allow sign in via one-time email codes
                  </p>
                </div>
                <input
                  type="hidden"
                  name={@form[:allow_email_otp_sign_in].name}
                  value="false"
                />
                <.toggle
                  id={@form[:allow_email_otp_sign_in].id}
                  name={@form[:allow_email_otp_sign_in].name}
                  value="true"
                  checked={
                    Phoenix.HTML.Form.normalize_value(
                      "checkbox",
                      @form[:allow_email_otp_sign_in].value
                    )
                  }
                />
              </div>
            </div>
            <.actor_group_picker
              pending_additions={@pending_group_additions}
              pending_removals={@pending_group_removals}
              current_groups={@groups}
              search_results={@group_search_results}
              account={@account}
            />
          </div>
          <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
            <button
              type="button"
              phx-click="cancel_actor_edit_form"
              class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)]"
            >
              Save Changes
            </button>
          </div>
        </.form>
      </div>
      <%!-- New actor creation panel --%>
      <div :if={@creating_actor} class="flex flex-col h-full overflow-hidden">
        <%!-- Header --%>
        <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
          <div class="flex items-center justify-between gap-3">
            <div class="flex items-center gap-3">
              <div class="inline-flex items-center justify-center w-8 h-8 rounded-full bg-neutral-100 dark:bg-neutral-800">
                <.icon name="remix-add-line" class="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
              </div>
              <div>
                <h2 class="text-sm font-semibold text-[var(--text-primary)]">New Actor</h2>
                <p class="text-xs text-[var(--text-tertiary)]">
                  {if @new_actor_type,
                    do: if(@new_actor_type == :user, do: "User", else: "Service Account"),
                    else: "Select a type to continue"}
                </p>
              </div>
            </div>
            <button
              phx-click="close_panel"
              class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
              title="Close (Esc)"
            >
              <.icon name="remix-close-line" class="w-4 h-4" />
            </button>
          </div>
        </div>
        <%!-- Type selection --%>
        <div :if={is_nil(@new_actor_type)} class="flex-1 overflow-y-auto p-5">
          <div class="grid grid-cols-2 gap-3">
            <button
              type="button"
              phx-click="select_new_actor_type"
              phx-value-type="user"
              class="flex flex-col items-center justify-center gap-2 p-5 rounded-lg border-2 border-[var(--border)] hover:border-[var(--brand)] hover:bg-[var(--surface-raised)] transition-all text-center"
            >
              <.icon name="remix-user-line" class="w-8 h-8 text-[var(--text-secondary)]" />
              <span class="text-sm font-semibold text-[var(--text-primary)]">User</span>
              <span class="text-xs text-[var(--text-tertiary)]">
                Can sign in to Firezone Client apps or the admin portal
              </span>
            </button>
            <button
              type="button"
              phx-click="select_new_actor_type"
              phx-value-type="service_account"
              class="flex flex-col items-center justify-center gap-2 p-5 rounded-lg border-2 border-[var(--border)] hover:border-[var(--brand)] hover:bg-[var(--surface-raised)] transition-all text-center"
            >
              <.icon name="remix-server-line" class="w-8 h-8 text-[var(--text-secondary)]" />
              <span class="text-sm font-semibold text-[var(--text-primary)]">Service Account</span>
              <span class="text-xs text-[var(--text-tertiary)]">
                Used to authenticate headless Clients
              </span>
            </button>
          </div>
        </div>
        <%!-- User creation form --%>
        <.form
          :if={@new_actor_type == :user and @form}
          for={@form}
          phx-change="validate"
          phx-submit="create_user"
          class="flex flex-col flex-1 min-h-0 overflow-hidden"
        >
          <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
            <.input
              field={@form[:name]}
              label="Name"
              placeholder="Enter user name"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />
            <.input
              field={@form[:email]}
              label="Email"
              type="email"
              placeholder="user@example.com"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />
            <div>
              <label class="block text-sm font-medium text-[var(--text-secondary)] mb-2">Role</label>
              <div class="grid grid-cols-2 gap-2">
                <div>
                  <.input
                    id={"#{@form[:type].id}--user"}
                    type="radio_button_group"
                    field={@form[:type]}
                    value="account_user"
                    checked={@form[:type].value in [:account_user, "account_user"]}
                    disabled={false}
                  />
                  <label
                    for={"#{@form[:type].id}--user"}
                    class="flex flex-col gap-1 p-3 rounded-lg border border-[var(--border)] cursor-pointer peer-checked:border-[var(--brand)] peer-checked:bg-[var(--surface-raised)] hover:bg-[var(--surface-raised)] transition-colors"
                  >
                    <span class="flex items-center gap-1.5 text-xs font-semibold text-[var(--text-primary)]">
                      <.icon name="remix-user-line" class="w-3.5 h-3.5" /> User
                    </span>
                    <span class="text-[11px] text-[var(--text-tertiary)]">
                      Sign in to Client apps and portal
                    </span>
                  </label>
                </div>
                <div>
                  <.input
                    id={"#{@form[:type].id}--admin"}
                    type="radio_button_group"
                    field={@form[:type]}
                    value="account_admin_user"
                    checked={@form[:type].value in [:account_admin_user, "account_admin_user"]}
                    disabled={false}
                  />
                  <label
                    for={"#{@form[:type].id}--admin"}
                    class="flex flex-col gap-1 p-3 rounded-lg border border-[var(--border)] cursor-pointer peer-checked:border-[var(--brand)] peer-checked:bg-[var(--surface-raised)] hover:bg-[var(--surface-raised)] transition-colors"
                  >
                    <span class="flex items-center gap-1.5 text-xs font-semibold text-[var(--text-primary)]">
                      <.icon name="remix-shield-check-line" class="w-3.5 h-3.5" /> Admin
                    </span>
                    <span class="text-[11px] text-[var(--text-tertiary)]">
                      Full access to manage this account
                    </span>
                  </label>
                </div>
              </div>
            </div>
            <div id="new-allow-email-otp-checkbox" phx-update="ignore">
              <div class="flex items-center justify-between py-1">
                <div>
                  <p class="text-sm font-medium text-[var(--text-secondary)]">Email OTP Sign In</p>
                  <p class="text-[11px] text-[var(--text-tertiary)]">
                    Allow sign in via one-time email codes
                  </p>
                </div>
                <input
                  type="hidden"
                  name={@form[:allow_email_otp_sign_in].name}
                  value="false"
                />
                <.toggle
                  id={@form[:allow_email_otp_sign_in].id}
                  name={@form[:allow_email_otp_sign_in].name}
                  value="true"
                  checked={
                    Phoenix.HTML.Form.normalize_value(
                      "checkbox",
                      @form[:allow_email_otp_sign_in].value
                    )
                  }
                />
              </div>
            </div>
            <.actor_group_picker
              pending_additions={@pending_group_additions}
              pending_removals={@pending_group_removals}
              current_groups={[]}
              search_results={@group_search_results}
              account={@account}
            />
          </div>
          <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
            <button
              type="button"
              phx-click="close_panel"
              class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)]"
            >
              Create User
            </button>
          </div>
        </.form>
        <%!-- Service account creation form --%>
        <.form
          :if={@new_actor_type == :service_account and @form}
          for={@form}
          phx-change="validate"
          phx-submit="create_service_account"
          class="flex flex-col flex-1 min-h-0 overflow-hidden"
        >
          <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
            <.input
              field={@form[:name]}
              label="Name"
              placeholder="E.g. GitHub CI"
              autocomplete="off"
              phx-debounce="300"
              data-1p-ignore
              required
            />
            <div>
              <label class="block text-sm font-medium text-neutral-700 dark:text-neutral-300 mb-2">
                Token expiration
              </label>
              <input
                type="date"
                name="token_expiration"
                value={@token_expiration}
                class="block w-full rounded-md border-neutral-300 focus:border-accent-400 focus:ring-3 focus:ring-accent-200/50 text-sm"
              />
            </div>
            <.actor_group_picker
              pending_additions={@pending_group_additions}
              pending_removals={@pending_group_removals}
              current_groups={[]}
              search_results={@group_search_results}
              account={@account}
            />
          </div>
          <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
            <button
              type="button"
              phx-click="close_panel"
              class="px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)]"
            >
              Create Service Account
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp actor_group_picker(assigns) do
    ~H"""
    <div>
      <% visible_count =
        length(@current_groups) - length(@pending_removals) + length(@pending_additions) %>
      <h3 class="text-sm font-medium text-[var(--text-secondary)] mb-2">
        Groups ({visible_count})
      </h3>
      <div class="border border-[var(--border)] rounded-md overflow-hidden">
        <%!-- Search input --%>
        <div
          class="p-3 bg-[var(--surface-raised)] border-b border-[var(--border)] relative"
          phx-click-away="blur_group_search"
        >
          <div class="relative">
            <.icon
              name="remix-search-line"
              class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3 h-3 text-[var(--text-tertiary)] pointer-events-none"
            />
            <input
              type="text"
              name="value"
              placeholder="Search to add groups..."
              phx-change="search_actor_groups"
              phx-focus="focus_group_search"
              phx-debounce="300"
              autocomplete="off"
              data-1p-ignore
              class="w-full pl-7 pr-3 py-1.5 text-xs rounded border border-[var(--border)] bg-[var(--surface)] text-[var(--text-primary)] placeholder:text-[var(--text-muted)] outline-none focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30 transition-colors"
            />
          </div>
          <div
            :if={@search_results != nil}
            class="absolute z-10 left-3 right-3 mt-1 bg-[var(--surface-overlay)] border border-[var(--border)] rounded-lg shadow-lg max-h-48 overflow-y-auto"
          >
            <button
              :for={group <- @search_results}
              type="button"
              phx-click="add_pending_group"
              phx-value-group_id={group.id}
              class="w-full text-left px-3 py-2 hover:bg-[var(--surface-raised)] border-b border-[var(--border)] last:border-b-0 transition-colors text-xs text-[var(--text-primary)]"
            >
              {group.name}
            </button>
            <div
              :if={@search_results == []}
              class="px-3 py-4 text-center text-xs text-[var(--text-tertiary)]"
            >
              No static groups found
            </div>
          </div>
        </div>
        <%!-- Group list --%>
        <ul class="divide-y divide-[var(--border)] max-h-48 overflow-y-auto">
          <li
            :for={group <- @current_groups}
            class="px-3 py-2.5 flex items-center justify-between group"
          >
            <p class="text-xs font-medium text-[var(--text-primary)] flex-1 min-w-0 truncate">
              {group.name}
            </p>
            <div class="ml-4 flex items-center gap-2 shrink-0">
              <span
                :if={group.id not in @pending_removals}
                class="text-xs text-[var(--text-tertiary)]"
              >
                Current
              </span>
              <span :if={group.id in @pending_removals} class="text-xs text-red-600 font-medium">
                To Remove
              </span>
              <button
                :if={group.id not in @pending_removals}
                type="button"
                phx-click="add_pending_group_removal"
                phx-value-group_id={group.id}
                class="shrink-0 text-[var(--text-tertiary)] hover:text-[var(--status-error)] transition-colors"
              >
                <.icon name="remix-user-minus-line" class="w-4 h-4" />
              </button>
              <button
                :if={group.id in @pending_removals}
                type="button"
                phx-click="undo_pending_group_removal"
                phx-value-group_id={group.id}
                class="shrink-0 text-[var(--text-tertiary)] hover:text-[var(--text-primary)] transition-colors"
              >
                <.icon name="remix-arrow-go-back-line" class="w-4 h-4" />
              </button>
            </div>
          </li>
          <li
            :for={group <- @pending_additions}
            class="px-3 py-2.5 flex items-center justify-between group"
          >
            <p class="text-xs font-medium text-[var(--text-primary)] flex-1 min-w-0 truncate">
              {group.name}
            </p>
            <div class="ml-4 flex items-center gap-2 shrink-0">
              <span class="text-xs text-green-600 font-medium">To Add</span>
              <button
                type="button"
                phx-click="remove_pending_group_addition"
                phx-value-group_id={group.id}
                class="shrink-0 text-[var(--text-tertiary)] hover:text-[var(--status-error)] transition-colors"
              >
                <.icon name="remix-user-minus-line" class="w-4 h-4" />
              </button>
            </div>
          </li>
        </ul>
        <div
          :if={@current_groups == [] and @pending_additions == []}
          class="px-3 py-4 text-center text-xs text-[var(--text-tertiary)]"
        >
          No groups added yet.
        </div>
      </div>
    </div>
    """
  end

  defp actor_type_icon_circle(assigns) do
    ~H"""
    <div class={[
      "inline-flex items-center justify-center w-8 h-8 rounded-full",
      actor_type_icon_bg_color(@actor.type)
    ]}>
      <.actor_type_icon actor={@actor} class={"w-5 h-5 #{actor_type_icon_text_color(@actor.type)}"} />
    </div>
    """
  end

  defp actor_type_icon_with_badge(assigns) do
    ~H"""
    <div class="relative inline-flex shrink-0">
      <div class={[
        "inline-flex items-center justify-center w-8 h-8 rounded-full",
        actor_type_icon_bg_color(@actor.type)
      ]}>
        <.actor_type_icon actor={@actor} class={"w-5 h-5 #{actor_type_icon_text_color(@actor.type)}"} />
      </div>
      <span
        :if={@actor.identity_count > 0}
        class="absolute top-0 left-0 inline-flex items-center justify-center w-3.5 h-3.5 text-[8px] font-semibold text-white bg-neutral-800 rounded-full"
      >
        {@actor.identity_count}
      </span>
    </div>
    """
  end

  defp actor_type_icon_bg_color(:service_account), do: "bg-blue-100"
  defp actor_type_icon_bg_color(:account_admin_user), do: "bg-purple-100"
  defp actor_type_icon_bg_color(_), do: "bg-neutral-100"

  defp actor_type_icon_text_color(:service_account), do: "text-blue-800"
  defp actor_type_icon_text_color(:account_admin_user), do: "text-purple-800"
  defp actor_type_icon_text_color(_), do: "text-neutral-800"

  defp actor_type_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded-sm text-xs font-medium uppercase",
      actor_type_badge_color(@actor.type)
    ]}>
      {actor_display_type(@actor)}
    </span>
    """
  end

  defp actor_type_badge_color(:service_account), do: "bg-blue-100 text-blue-800"
  defp actor_type_badge_color(:account_admin_user), do: "bg-purple-100 text-purple-800"
  defp actor_type_badge_color(_), do: "bg-neutral-100 text-neutral-800"

  defp actor_display_type(%{type: :service_account}), do: "Service Account"
  defp actor_display_type(%{type: :account_admin_user}), do: "Admin"
  defp actor_display_type(%{type: :account_user}), do: "User"
  defp actor_display_type(_), do: "User"

  defp extract_idp_id(idp_id) do
    String.split(idp_id, ":", parts: 2) |> List.last()
  end

  # Utility helpers
  defp ensure_not_self(actor, subject) do
    if actor.id == subject.actor.id, do: {:error, :self_operation}, else: :ok
  end

  defp handle_success(socket, message) do
    socket
    |> put_flash(:success, message)
    |> reload_live_table!("actors")
    |> close_modal()
  end

  defp close_modal(socket) do
    if return_to = handle_return_to(socket) do
      push_navigate(socket, to: return_to)
    else
      push_patch(socket, to: ~p"/#{socket.assigns.account}/actors")
    end
  end

  defp handle_return_to(%{
         assigns: %{query_params: %{"return_to" => return_to}, current_path: current_path}
       })
       when not is_nil(return_to) and not is_nil(current_path) do
    validate_return_to(
      String.split(return_to, "/", parts: 2),
      String.split(current_path, "/", parts: 2)
    )
  end

  defp handle_return_to(_socket), do: nil

  defp validate_return_to([account | _ret_parts] = return_to, [account | _cur_parts]),
    do: Enum.join(return_to, "/")

  defp validate_return_to(_return_to, _current_path), do: nil

  # Changesets
  defp changeset(actor, attrs) do
    actor
    |> cast(attrs, [:name, :email, :type, :allow_email_otp_sign_in])
  end

  defp apply_group_membership_changes(socket, actor, subject) do
    Enum.each(socket.assigns.pending_group_additions, fn group ->
      Database.add_group_member(group.id, actor, subject)
    end)

    Enum.each(socket.assigns.pending_group_removals, fn group_id ->
      Database.remove_group_member(group_id, actor, subject)
    end)

    assign(socket, pending_group_additions: [], pending_group_removals: [])
  end

  # Helper functions
  defp parse_date_to_datetime(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

      {:error, _} ->
        nil
    end
  end

  # Consolidated token creation function
  defp create_actor_token(_actor, nil, _subject), do: {:ok, nil}
  defp create_actor_token(_actor, "", _subject), do: {:ok, nil}

  defp create_actor_token(actor, token_expiration, subject) do
    case parse_date_to_datetime(token_expiration) do
      nil ->
        {:error, :invalid_date}

      expires_at ->
        # Build the token attributes
        attrs = %{"expires_at" => expires_at}

        case Authentication.create_headless_client_token(actor, attrs, subject) do
          {:ok, token} ->
            encoded_token = Authentication.encode_fragment!(token)
            {:ok, {token, encoded_token}}

          error ->
            error
        end
    end
  end

  # Firezone client user agents (e.g., "Windows/10.0", "Mac OS/15.0")
  @firezone_client_patterns [
    {"Windows/", "os-windows"},
    {"Mac OS/", "os-macos"},
    {"iOS/", "os-ios"},
    {"Android/", "os-android"},
    {"Ubuntu/", "os-ubuntu"},
    {"Debian/", "os-debian"},
    {"Manjaro/", "os-manjaro"},
    {"CentOS/", "os-linux"},
    {"Fedora/", "os-linux"}
  ]

  # Browser user agents (standard Mozilla format)
  @browser_patterns [
    {"iPhone", "os-ios"},
    {"iPad", "os-ios"},
    {"Android", "os-android"},
    {"Macintosh", "os-macos"},
    {"Mac OS X", "os-macos"},
    {"Windows NT", "os-windows"},
    {"linux", "os-linux"}
  ]

  defp detect_os_icon(user_agent) do
    find_matching_pattern(user_agent, @firezone_client_patterns) ||
      find_matching_pattern(user_agent, @browser_patterns) ||
      detect_x11_linux(user_agent)
  end

  defp find_matching_pattern(user_agent, patterns) do
    Enum.find_value(patterns, fn {pattern, icon} ->
      if String.contains?(user_agent, pattern), do: icon
    end)
  end

  defp detect_x11_linux(user_agent) do
    if String.contains?(user_agent, "X11") and String.contains?(user_agent, "Linux") do
      "os-linux"
    end
  end

  defp token_location(%{latest_session: nil}), do: nil

  defp token_location(%{latest_session: session}) do
    cond do
      session.remote_ip_location_city && session.remote_ip_location_region ->
        "#{session.remote_ip_location_city}, #{session.remote_ip_location_region}"

      session.remote_ip_location_region ->
        session.remote_ip_location_region

      true ->
        nil
    end
  end

  # Helper functions for session display
  defp session_user_agent_icon(user_agent) when is_binary(user_agent) do
    detect_os_icon(user_agent) || "remix-computer-line"
  end

  defp session_user_agent_icon(_), do: "remix-computer-line"

  defp session_location(session) do
    cond do
      session.remote_ip_location_city && session.remote_ip_location_region ->
        "#{session.remote_ip_location_city}, #{session.remote_ip_location_region}"

      session.remote_ip_location_region ->
        session.remote_ip_location_region

      true ->
        nil
    end
  end

  defp other_enabled_admins_exist?(actor, subject) do
    case actor do
      %{type: :account_admin_user, account_id: account_id, id: id} ->
        Database.other_enabled_admins_exist?(account_id, id, subject)

      _ ->
        false
    end
  end

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.ExternalIdentity
    alias Portal.Actor
    alias Portal.ClientSession
    alias Portal.Presence
    alias Portal.Safe
    alias Portal.Directory
    alias Portal.Repo.Filter

    def all do
      from(actors in Actor, as: :actors)
      |> where([actors: actors], actors.type != :api_client)
      |> select_merge([actors: actors], %{
        email:
          fragment(
            "COALESCE(?, (SELECT email FROM external_identities WHERE actor_id = ? AND email IS NOT NULL ORDER BY inserted_at DESC LIMIT 1))",
            actors.email,
            actors.id
          ),
        identity_count:
          fragment(
            "(SELECT COUNT(*) FROM external_identities WHERE actor_id = ?)",
            actors.id
          )
      })
    end

    def cursor_fields do
      [
        {:actors, :asc, :inserted_at},
        {:actors, :asc, :id}
      ]
    end

    def filters do
      [
        %Filter{
          name: :name_or_email,
          title: "Name or Email",
          type: {:string, :websearch},
          fun: &filter_by_name_or_email/2
        },
        %Filter{
          name: :status,
          title: "Status",
          type: :string,
          values: [
            {"Active", "active"},
            {"Disabled", "disabled"}
          ],
          fun: &filter_by_status/2
        },
        %Filter{
          name: :type,
          title: "Role",
          type: {:string, :select},
          values: [
            {"Admins", "admin"},
            {"Users", "user"},
            {"Service Accounts", "service_account"}
          ],
          fun: &filter_by_type/2
        },
        %Filter{
          name: :directory_id,
          title: "Directory",
          type: {:string, :select},
          values: &directory_values/1,
          fun: &filter_by_directory/2
        }
      ]
    end

    # Define a simple struct-like module for directory options
    defmodule DirectoryOption do
      defstruct [:id, :name]
    end

    defp directory_values(subject) do
      directories =
        from(d in Directory,
          where: d.account_id == ^subject.account.id,
          left_join: google in Portal.Google.Directory,
          on: google.id == d.id and d.type == :google,
          left_join: entra in Portal.Entra.Directory,
          on: entra.id == d.id and d.type == :entra,
          left_join: okta in Portal.Okta.Directory,
          on: okta.id == d.id and d.type == :okta,
          select: %{
            id: d.id,
            name: fragment("COALESCE(?, ?, ?)", google.name, entra.name, okta.name),
            type: d.type
          },
          order_by: [asc: fragment("COALESCE(?, ?, ?)", google.name, entra.name, okta.name)]
        )
        |> Safe.scoped(subject, :replica)
        |> Safe.all()
        |> case do
          {:error, _} ->
            []

          directories ->
            directories
            |> Enum.map(fn %{id: id, name: name} ->
              %DirectoryOption{id: id, name: name}
            end)
        end

      # Add Firezone option at the beginning
      [%DirectoryOption{id: "firezone", name: "Firezone"} | directories]
    end

    def filter_by_status(queryable, "active") do
      {queryable, dynamic([actors: actors], is_nil(actors.disabled_at))}
    end

    def filter_by_status(queryable, "disabled") do
      {queryable, dynamic([actors: actors], not is_nil(actors.disabled_at))}
    end

    def filter_by_type(queryable, "admin") do
      {queryable, dynamic([actors: actors], actors.type == :account_admin_user)}
    end

    def filter_by_type(queryable, "user") do
      {queryable, dynamic([actors: actors], actors.type == :account_user)}
    end

    def filter_by_type(queryable, "service_account") do
      {queryable, dynamic([actors: actors], actors.type == :service_account)}
    end

    def filter_by_directory(queryable, "firezone") do
      # Firezone directory - actors with no directory-linked identities
      # (either no identities, or identities without directory_id)
      identity_subquery =
        from(i in ExternalIdentity,
          where: not is_nil(i.directory_id),
          select: i.actor_id,
          distinct: true
        )

      {queryable, dynamic([actors: actors], actors.id not in subquery(identity_subquery))}
    end

    def filter_by_directory(queryable, directory_id) do
      # Filter for actors that have identities from a specific directory
      identity_subquery =
        from(i in ExternalIdentity,
          where: i.directory_id == ^directory_id,
          select: i.actor_id,
          distinct: true
        )

      {queryable, dynamic([actors: actors], actors.id in subquery(identity_subquery))}
    end

    def filter_by_name_or_email(queryable, search_term) do
      {queryable,
       dynamic(
         [actors: actors],
         fulltext_search(actors.name, ^search_term) or
           fulltext_search(actors.email, ^search_term)
       )}
    end

    def list_actors(subject, opts \\ []) do
      all()
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_account(account_id) do
      from(a in Portal.Account, where: a.id == ^account_id)
      |> Safe.unscoped(:replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def get_actor(id, subject) do
      result =
        from(a in Actor, as: :actors)
        |> where([actors: a], a.id == ^id)
        |> where([actors: a], a.type != :api_client)
        |> Safe.scoped(subject, :replica)
        |> Safe.one(fallback_to_primary: true)

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        actor -> {:ok, actor}
      end
    end

    def get_identities_for_actor(actor_id, subject) do
      from(i in ExternalIdentity, as: :identities)
      |> where([identities: i], i.actor_id == ^actor_id)
      |> join(:left, [identities: i], d in assoc(i, :directory), as: :directory)
      |> join(:left, [directory: d], gd in Portal.Google.Directory,
        on: gd.id == d.id and d.type == :google,
        as: :google_directory
      )
      |> join(:left, [directory: d], ed in Portal.Entra.Directory,
        on: ed.id == d.id and d.type == :entra,
        as: :entra_directory
      )
      |> join(:left, [directory: d], od in Portal.Okta.Directory,
        on: od.id == d.id and d.type == :okta,
        as: :okta_directory
      )
      |> select_merge(
        [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
        %{
          directory_name:
            fragment(
              "COALESCE(?, ?, ?, 'Firezone')",
              gd.name,
              ed.name,
              od.name
            )
        }
      )
      |> order_by([identities: i], desc: i.inserted_at)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def other_enabled_admins_exist?(account_id, actor_id, subject) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: a.id != ^actor_id,
        where: is_nil(a.disabled_at)
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.exists?(fallback_to_primary: true)
    end

    def get_client_tokens_for_actor(actor_id, subject) do
      tokens =
        from(c in ClientToken, as: :client_tokens)
        |> where([client_tokens: c], c.actor_id == ^actor_id)
        |> order_by([client_tokens: c], desc: c.inserted_at)
        |> Safe.scoped(subject, :replica)
        |> Safe.all()

      tokens
      |> preload_latest_sessions_for_tokens()
      |> Presence.Clients.preload_client_tokens_presence()
    end

    defp preload_latest_sessions_for_tokens(tokens) do
      account_ids = tokens |> Enum.map(& &1.account_id) |> Enum.uniq()
      token_ids = Enum.map(tokens, & &1.id)

      sessions_by_token_id =
        from(s in ClientSession,
          where: s.account_id in ^account_ids,
          where: s.client_token_id in ^token_ids,
          distinct: s.client_token_id,
          order_by: [asc: s.client_token_id, desc: s.inserted_at]
        )
        |> Safe.unscoped(:replica)
        |> Safe.all()
        |> Map.new(&{&1.client_token_id, &1})

      Enum.map(tokens, fn token ->
        %{token | latest_session: Map.get(sessions_by_token_id, token.id)}
      end)
    end

    def get_identity_by_id(identity_id, subject) do
      from(i in ExternalIdentity, as: :identities)
      |> where([identities: i], i.id == ^identity_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def get_client_token_by_id(token_id, subject) do
      from(c in ClientToken, as: :client_tokens)
      |> where([client_tokens: c], c.id == ^token_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def get_portal_sessions_for_actor(actor_id, subject) do
      from(ps in PortalSession, as: :portal_sessions)
      |> where([portal_sessions: ps], ps.actor_id == ^actor_id)
      |> join(:left, [portal_sessions: ps], ap in assoc(ps, :auth_provider), as: :auth_provider)
      |> select_merge([auth_provider: ap], %{
        auth_provider_type: type(ap.type, :string),
        auth_provider_name:
          fragment(
            """
            COALESCE(
              (SELECT name FROM google_auth_providers WHERE id = ?),
              (SELECT name FROM entra_auth_providers WHERE id = ?),
              (SELECT name FROM okta_auth_providers WHERE id = ?),
              (SELECT name FROM oidc_auth_providers WHERE id = ?),
              (SELECT name FROM userpass_auth_providers WHERE id = ?),
              (SELECT name FROM email_otp_auth_providers WHERE id = ?)
            )
            """,
            ap.id,
            ap.id,
            ap.id,
            ap.id,
            ap.id,
            ap.id
          )
      })
      |> order_by([portal_sessions: ps], desc: ps.inserted_at)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
      |> Presence.PortalSessions.preload_portal_sessions_presence()
    end

    def get_portal_session_by_id(session_id, subject) do
      from(ps in PortalSession, as: :portal_sessions)
      |> where([portal_sessions: ps], ps.id == ^session_id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one(fallback_to_primary: true)
    end

    def get_groups_for_actor(actor_id, subject) do
      from(g in Portal.Group, as: :groups)
      |> join(:inner, [groups: g], m in Portal.Membership,
        on: m.group_id == g.id and m.account_id == g.account_id,
        as: :membership
      )
      |> join(:left, [groups: g], d in assoc(g, :directory), as: :directory)
      |> join(:left, [directory: d], gd in Portal.Google.Directory,
        on: gd.id == d.id and d.type == :google,
        as: :google_directory
      )
      |> join(:left, [directory: d], ed in Portal.Entra.Directory,
        on: ed.id == d.id and d.type == :entra,
        as: :entra_directory
      )
      |> join(:left, [directory: d], od in Portal.Okta.Directory,
        on: od.id == d.id and d.type == :okta,
        as: :okta_directory
      )
      |> where([membership: m], m.actor_id == ^actor_id)
      |> select_merge(
        [directory: d, google_directory: gd, entra_directory: ed, okta_directory: od],
        %{
          directory_type: d.type,
          directory_name: fragment("COALESCE(?, ?, ?)", gd.name, ed.name, od.name)
        }
      )
      |> order_by([groups: g], asc: g.name)
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    def create(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def create_service_account_with_token(changeset, token_expiration, subject, token_creator_fn) do
      Safe.transact(fn ->
        with {:ok, actor} <- create(changeset, subject),
             token_result <- token_creator_fn.(actor, token_expiration, subject) do
          {:ok, {actor, token_result}}
        end
      end)
    end

    def update(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete(actor, subject) do
      actor
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    @spec search_groups_for_actor(String.t(), Ecto.UUID.t() | nil, map()) ::
            {:error, any()} | list(Portal.Group.t())
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

    @spec add_group_member(Ecto.UUID.t(), Portal.Actor.t(), map()) ::
            {:ok, Portal.Membership.t()} | {:error, Ecto.Changeset.t()}
    def add_group_member(group_id, actor, subject) do
      import Ecto.Changeset

      %Portal.Membership{}
      |> change(%{account_id: actor.account_id, group_id: group_id, actor_id: actor.id})
      |> Portal.Membership.changeset()
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    @spec remove_group_member(Ecto.UUID.t(), Portal.Actor.t(), map()) ::
            {:ok, Portal.Membership.t()} | {:error, any()}
    def remove_group_member(group_id, actor, subject) do
      from(m in Portal.Membership, as: :memberships)
      |> where([memberships: m], m.group_id == ^group_id and m.actor_id == ^actor.id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!()
      |> then(&(Safe.scoped(&1, subject) |> Safe.delete()))
    end
  end
end
