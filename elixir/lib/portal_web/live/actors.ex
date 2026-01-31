defmodule PortalWeb.Actors do
  use PortalWeb, :live_view

  alias __MODULE__.Database

  alias Portal.Actor
  alias Portal.Authentication
  alias Portal.ExternalIdentity
  alias Portal.PortalSession
  alias Portal.ClientToken

  import Ecto.Changeset
  import PortalWeb.Clients.Components, only: [client_os_icon_name: 1]

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Actors")
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
       actor_type: :user
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
       token_expiration: default_expiration
     )}
  end

  # Show Actor Modal
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    actor = Database.get_actor!(id, socket.assigns.subject)

    # Load identities and tokens/sessions based on actor type
    identities = Database.get_identities_for_actor(actor.id, socket.assigns.subject)
    groups = Database.get_groups_for_actor(actor.id, socket.assigns.subject)

    # Load tokens and sessions based on actor type
    {tokens, sessions} =
      if actor.type == :service_account do
        {Database.get_client_tokens_for_actor(actor.id, socket.assigns.subject), []}
      else
        # Users have both client tokens and portal sessions
        {Database.get_client_tokens_for_actor(actor.id, socket.assigns.subject),
         Database.get_portal_sessions_for_actor(actor.id, socket.assigns.subject)}
      end

    socket = handle_live_tables_params(socket, params, uri)

    default_tab = if actor.type == :service_account, do: "tokens", else: "identities"

    socket =
      socket
      |> assign(
        actor: actor,
        active_tab: default_tab,
        identities: identities,
        groups: groups,
        tokens: tokens,
        sessions: sessions
      )
      |> assign_new(:created_token, fn -> nil end)

    {:noreply, socket}
  end

  # Add Token Modal
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :add_token}} = socket) do
    actor = Database.get_actor!(id, socket.assigns.subject)
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
  end

  # Edit Actor Modal
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    actor = Database.get_actor!(id, socket.assigns.subject)
    socket = handle_live_tables_params(socket, params, uri)
    changeset = changeset(actor, %{})

    is_last_admin =
      actor.type == :account_admin_user and
        not other_enabled_admins_exist?(actor, socket.assigns.subject)

    {:noreply,
     assign(socket,
       actor: actor,
       form: to_form(changeset),
       is_last_admin: is_last_admin
     )}
  end

  # Default handler
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> handle_live_tables_params(params, uri)
      |> assign(created_token: nil)

    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modal(socket)}
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
              |> put_flash(:success, "User created successfully")
              |> reload_live_table!("actors")
              |> push_patch(
                to:
                  ~p"/#{socket.assigns.account}/actors/#{actor.id}?#{socket.assigns.query_params}"
              )

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
            |> reload_live_table!("actors")
            |> push_patch(
              to: ~p"/#{socket.assigns.account}/actors/#{actor.id}?#{socket.assigns.query_params}"
            )

          {:noreply, socket}

        {:ok, {actor, {:ok, {_token, encoded_token}}}} ->
          socket =
            socket
            |> reload_live_table!("actors")
            |> assign(created_token: encoded_token)
            |> push_patch(
              to: ~p"/#{socket.assigns.account}/actors/#{actor.id}?#{socket.assigns.query_params}"
            )

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

    # Prevent changing the last admin to account_user
    new_type = get_change(changeset, :type)

    if actor.type == :account_admin_user and new_type == :account_user and
         not other_enabled_admins_exist?(actor, socket.assigns.subject) do
      changeset =
        add_error(
          changeset,
          :type,
          "Cannot change role. At least one admin must remain in the account."
        )

      {:noreply, assign(socket, form: to_form(changeset))}
    else
      case Database.update(changeset, socket.assigns.subject) do
        {:ok, actor} ->
          socket =
            socket
            |> put_flash(:success_inline, "Actor updated successfully")
            |> reload_live_table!("actors")
            |> push_patch(
              to: ~p"/#{socket.assigns.account}/actors/#{actor.id}?#{socket.assigns.query_params}"
            )

          {:noreply, socket}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = Database.get_actor!(id, socket.assigns.subject)

    # Prevent users from deleting themselves
    if actor.id == socket.assigns.subject.actor.id do
      {:noreply, put_flash(socket, :error, "You cannot delete yourself")}
    else
      case Database.delete(actor, socket.assigns.subject) do
        {:ok, _actor} ->
          {:noreply, handle_success(socket, "Actor deleted successfully")}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, "You are not authorized to delete this actor")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to delete actor")}
      end
    end
  end

  def handle_event("disable", %{"id" => id}, socket) do
    actor = Database.get_actor!(id, socket.assigns.subject)

    # Prevent users from disabling themselves
    if actor.id == socket.assigns.subject.actor.id do
      {:noreply, put_flash(socket, :error, "You cannot disable yourself")}
    else
      case actor
           |> change()
           |> put_change(:disabled_at, DateTime.utc_now())
           |> Database.update(socket.assigns.subject) do
        {:ok, updated_actor} ->
          socket = reload_live_table!(socket, "actors")

          # If the modal is open for this actor, update it
          socket =
            if Map.get(socket.assigns, :actor) && socket.assigns.actor.id == id do
              assign(socket, actor: updated_actor)
            else
              socket
            end

          {:noreply, put_flash(socket, :success_inline, "Actor disabled successfully")}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, "You are not authorized to disable this actor")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to disable actor")}
      end
    end
  end

  def handle_event("enable", %{"id" => id}, socket) do
    actor = Database.get_actor!(id, socket.assigns.subject)

    case actor
         |> change()
         |> put_change(:disabled_at, nil)
         |> Database.update(socket.assigns.subject) do
      {:ok, updated_actor} ->
        socket = reload_live_table!(socket, "actors")

        # If the modal is open for this actor, update it
        socket =
          if Map.get(socket.assigns, :actor) && socket.assigns.actor.id == id do
            assign(socket, actor: updated_actor)
          else
            socket
          end

        {:noreply, put_flash(socket, :success_inline, "Actor enabled successfully")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to enable actor")}
    end
  end

  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  def handle_event("validate_token", params, socket) do
    token_expiration = Map.get(params, "token_expiration", socket.assigns.token_expiration)

    {:noreply, assign(socket, token_expiration: token_expiration)}
  end

  def handle_event("create_token", params, socket) do
    actor = socket.assigns.actor
    token_expiration = Map.get(params, "token_expiration")

    case create_actor_token(actor, token_expiration, socket.assigns.subject) do
      {:ok, {_token, encoded_token}} ->
        socket =
          socket
          |> assign(created_token: encoded_token)
          |> push_patch(
            to: ~p"/#{socket.assigns.account}/actors/#{actor.id}?#{socket.assigns.query_params}"
          )

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create token")}
    end
  end

  def handle_event("delete_token", %{"id" => token_id}, socket) do
    token = Database.get_client_token_by_id(token_id, socket.assigns.subject)
    entity = if socket.assigns.actor.type == :service_account, do: "token", else: "session"

    if token do
      case Database.delete(token, socket.assigns.subject) do
        {:ok, _} ->
          tokens =
            Database.get_client_tokens_for_actor(socket.assigns.actor.id, socket.assigns.subject)

          {:noreply,
           socket
           |> assign(tokens: tokens)
           |> put_flash(:success_inline, "#{String.capitalize(entity)} deleted successfully")}

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
        Database.get_portal_sessions_for_actor(socket.assigns.actor.id, socket.assigns.subject)

      socket = assign(socket, sessions: sessions)
      {:noreply, put_flash(socket, :success_inline, "Session deleted successfully")}
    else
      {:noreply, put_flash(socket, :error, "Session not found")}
    end
  end

  def handle_event("delete_identity", %{"id" => identity_id}, socket) do
    case Database.get_identity_by_id(identity_id, socket.assigns.subject) do
      nil ->
        {:noreply, put_flash(socket, :error, "Identity not found")}

      identity ->
        case Database.delete(identity, socket.assigns.subject) do
          {:ok, _} ->
            # Reload identities for the actor
            identities =
              Database.get_identities_for_actor(socket.assigns.actor.id, socket.assigns.subject)

            socket = assign(socket, identities: identities)
            {:noreply, put_flash(socket, :success_inline, "Identity deleted successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete identity")}
        end
    end
  end

  def handle_event("send_welcome_email", %{"id" => actor_id}, socket) do
    actor = socket.assigns.actor

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
          socket =
            socket
            |> put_flash(:success_inline, "Welcome email sent to #{actor.email}")

          {:noreply, socket}

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

  def handle_actors_update!(socket, list_opts) do
    with {:ok, actors, metadata} <- Database.list_actors(socket.assigns.subject, list_opts) do
      {:ok, assign(socket, actors: actors, actors_metadata: metadata)}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/actors"}>{@page_title}</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Actors
      </:title>

      <:action>
        <.docs_action path="/deploy/users" />
      </:action>

      <:action>
        <.add_button navigate={~p"/#{@account}/actors/add?#{@query_params}"}>
          Add Actor
        </.add_button>
      </:action>

      <:help>
        Actors are the people and services that can access your Resources.
      </:help>

      <:content>
        <.live_table
          id="actors"
          rows={@actors}
          row_id={&"actor-#{&1.id}"}
          row_patch={&row_patch_path(&1, @query_params)}
          filters={@filters_by_table_id["actors"]}
          filter={@filter_form_by_table_id["actors"]}
          ordered_by={@order_by_table_id["actors"]}
          metadata={@actors_metadata}
        >
          <:col :let={actor} class="w-12">
            <.actor_type_icon_with_badge actor={actor} />
          </:col>
          <:col :let={actor} field={{:actors, :name}} label="name" class="w-3/12">
            {actor.name}
          </:col>
          <:col :let={actor} field={{:actors, :email}} label="email">
            <span class="block truncate" title={actor.email}>
              {actor.email || "-"}
            </span>
          </:col>
          <:col :let={actor} label="status" class="w-1/12">
            <%= if actor.disabled_at do %>
              <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800">
                Disabled
              </span>
            <% else %>
              <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800">
                Active
              </span>
            <% end %>
          </:col>
          <:col :let={actor} field={{:actors, :updated_at}} label="last updated" class="w-2/12">
            <.relative_datetime datetime={actor.updated_at} />
          </:col>
          <:empty>
            <div class="flex justify-center text-center text-neutral-500 p-4">
              <div class="w-auto pb-4">
                No actors to display.
                <.link class={[link_style()]} navigate={~p"/#{@account}/actors/add"}>
                  Add an actor
                </.link>
                to get started.
              </div>
            </div>
          </:empty>
        </.live_table>
      </:content>
    </.section>

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
            class="flex flex-col items-center justify-center p-6 border-2 border-neutral-200 rounded-lg hover:border-accent-500 hover:bg-neutral-50 transition-all"
          >
            <.icon name="hero-user" class="w-12 h-12 mb-3 text-neutral-600" />
            <span class="text-lg font-semibold text-neutral-900">User</span>
            <span class="text-sm text-neutral-600 mt-2 text-center">
              User accounts can sign in to the Firezone Client apps or to the admin portal
            </span>
          </button>

          <button
            type="button"
            phx-click="select_type"
            phx-value-type="service_account"
            class="flex flex-col items-center justify-center p-6 border-2 border-neutral-200 rounded-lg hover:border-accent-500 hover:bg-neutral-50 transition-all"
          >
            <.icon name="hero-server" class="w-12 h-12 mb-3 text-neutral-600" />
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
                class="block w-full rounded-lg border-neutral-300 focus:border-accent-400 focus:ring focus:ring-accent-200 focus:ring-opacity-50"
              />
            </div>
          </div>
        </.form>
      </:body>
      <:confirm_button form="service-account-form" type="submit">Create</:confirm_button>
    </.modal>

    <!-- Show Actor Modal -->
    <.modal
      :if={@live_action == :show}
      id="show-actor-modal"
      on_close="close_modal"
    >
      <:title>
        <div class="flex items-center gap-3">
          <.actor_type_icon actor={@actor} class="w-8 h-8" />
          <div>
            <div class="flex items-center gap-2">
              <span>{@actor.name}</span>
              <.actor_type_badge actor={@actor} />
              <%= if @actor.disabled_at do %>
                <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800">
                  Disabled
                </span>
              <% end %>
            </div>
          </div>
        </div>
      </:title>
      <:body>
        <.flash id="actor-success-inline-show" kind={:success_inline} style="inline" flash={@flash} />
        <%= if @created_token do %>
          <div
            id="created-token-display"
            class="bg-green-50 border border-green-200 rounded-lg p-4 mb-4"
          >
            <div class="flex items-start gap-3">
              <.icon name="hero-check-circle" class="w-5 h-5 text-green-600 flex-shrink-0 mt-0.5" />
              <div class="flex-1">
                <h4 class="text-sm font-semibold text-green-900 mb-2">Token Created Successfully</h4>
                <p class="text-sm text-green-800 mb-3">
                  Save this token now. You won't be able to see it again!
                </p>
                <div id="created-token-copy-container" class="relative" phx-hook="CopyClipboard">
                  <code
                    id="created-token-copy-container-code"
                    class="block bg-white border border-green-300 rounded px-3 py-2 pr-24 text-sm font-mono text-neutral-900 break-all"
                  >
                    {@created_token}
                  </code>
                  <button
                    type="button"
                    data-copy-to-clipboard-target="created-token-copy-container-code"
                    data-copy-to-clipboard-content-type="innerHTML"
                    data-copy-to-clipboard-html-entities="true"
                    class="absolute top-1 right-1 px-3 py-1.5 text-sm font-medium text-green-700 bg-white border border-green-300 hover:bg-green-50 rounded inline-flex items-center"
                  >
                    <span
                      id="created-token-copy-container-default-message"
                      class="inline-flex items-center"
                    >
                      <.icon name="hero-clipboard-document" class="w-4 h-4" />
                    </span>
                    <span
                      id="created-token-copy-container-success-message"
                      class="inline-flex items-center hidden"
                    >
                      <.icon name="hero-check" class="w-4 h-4 text-green-700" />
                      <span class="ml-1 text-xs font-semibold">Copied!</span>
                    </span>
                  </button>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <div class="space-y-6">
          <!-- Actor Details -->
          <div>
            <div class="flex items-start justify-between mb-4">
              <div class="grid grid-cols-2 gap-4 text-sm flex-1">
                <div>
                  <p class="text-xs font-medium text-neutral-500 uppercase mb-1">Actor ID</p>
                  <p class="text-sm text-neutral-900 font-mono truncate" title={@actor.id}>
                    {@actor.id}
                  </p>
                </div>
                <div :if={@actor.email}>
                  <p class="text-xs font-medium text-neutral-500 uppercase mb-1">Email</p>
                  <p class="text-sm text-neutral-900 truncate" title={@actor.email}>
                    {@actor.email}
                  </p>
                </div>
                <div>
                  <p class="text-xs font-medium text-neutral-500 uppercase mb-1">Created</p>
                  <p class="text-sm text-neutral-900">
                    <.relative_datetime datetime={@actor.inserted_at} />
                  </p>
                </div>
                <div>
                  <p class="text-xs font-medium text-neutral-500 uppercase mb-1">Updated</p>
                  <p class="text-sm text-neutral-900">
                    <.relative_datetime datetime={@actor.updated_at} />
                  </p>
                </div>
                <div :if={@actor.type != :service_account}>
                  <p class="text-xs font-medium text-neutral-500 uppercase mb-1">Email OTP Sign In</p>
                  <div class="flex items-center gap-2">
                    <span
                      :if={@actor.allow_email_otp_sign_in}
                      class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800"
                    >
                      <.icon name="hero-check-circle" class="w-3.5 h-3.5 mr-1" /> Allowed
                    </span>
                    <span
                      :if={!@actor.allow_email_otp_sign_in}
                      class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-neutral-100 text-neutral-600"
                    >
                      <.icon name="hero-no-symbol" class="w-3.5 h-3.5 mr-1" /> Not Allowed
                    </span>
                  </div>
                </div>
              </div>
              <.popover placement="bottom-end" trigger="click">
                <:target>
                  <button
                    type="button"
                    class="text-neutral-500 hover:text-neutral-700 focus:outline-none ml-4"
                  >
                    <.icon name="hero-ellipsis-horizontal" class="w-6 h-6" />
                  </button>
                </:target>
                <:content>
                  <div class="py-1">
                    <.link
                      navigate={~p"/#{@account}/actors/#{@actor.id}/edit?#{@query_params}"}
                      class="px-3 py-2 text-sm text-neutral-800 rounded-lg hover:bg-neutral-100 flex items-center gap-2 whitespace-nowrap"
                    >
                      <.icon name="hero-pencil" class="w-4 h-4" /> Edit
                    </.link>
                    <.link
                      :if={@actor.type == :service_account}
                      navigate={~p"/#{@account}/actors/#{@actor.id}/add_token?#{@query_params}"}
                      class="px-3 py-2 text-sm text-neutral-800 rounded-lg hover:bg-neutral-100 flex items-center gap-2 whitespace-nowrap"
                    >
                      <.icon name="hero-key" class="w-4 h-4" /> Add Token
                    </.link>
                    <button
                      :if={@actor.type in [:account_user, :account_admin_user] and @actor.email}
                      type="button"
                      phx-click="send_welcome_email"
                      phx-value-id={@actor.id}
                      class="w-full px-3 py-2 text-sm text-blue-600 rounded-lg hover:bg-neutral-100 flex items-center gap-2 border-0 bg-transparent whitespace-nowrap"
                    >
                      <.icon name="hero-envelope" class="w-4 h-4" /> Send Welcome Email
                    </button>
                    <button
                      :if={is_nil(@actor.disabled_at) and @actor.id != @subject.actor.id}
                      type="button"
                      phx-click="disable"
                      phx-value-id={@actor.id}
                      class="w-full px-3 py-2 text-sm text-orange-600 rounded-lg hover:bg-neutral-100 flex items-center gap-2 border-0 bg-transparent whitespace-nowrap"
                    >
                      <.icon name="hero-lock-closed" class="w-4 h-4" /> Disable
                    </button>
                    <button
                      :if={not is_nil(@actor.disabled_at)}
                      type="button"
                      phx-click="enable"
                      phx-value-id={@actor.id}
                      class="w-full px-3 py-2 text-sm text-green-600 rounded-lg hover:bg-neutral-100 flex items-center gap-2 border-0 bg-transparent whitespace-nowrap"
                    >
                      <.icon name="hero-lock-open" class="w-4 h-4" /> Enable
                    </button>
                    <button
                      :if={@actor.id != @subject.actor.id}
                      type="button"
                      phx-click="delete"
                      phx-value-id={@actor.id}
                      class="w-full px-3 py-2 text-sm text-red-600 rounded-lg hover:bg-neutral-100 flex items-center gap-2 border-0 bg-transparent whitespace-nowrap"
                      data-confirm="Are you sure you want to delete this actor?"
                    >
                      <.icon name="hero-trash" class="w-4 h-4" /> Delete
                    </button>
                  </div>
                </:content>
              </.popover>
            </div>
          </div>
          <!-- Tabs -->
          <div class="border-b border-neutral-200">
            <nav class="-mb-px flex space-x-8">
              <%= if @actor.type != :service_account do %>
                <button
                  type="button"
                  phx-click="change_tab"
                  phx-value-tab="identities"
                  class={[
                    "py-4 px-1 border-b-2 font-medium text-sm flex items-center gap-2",
                    if(@active_tab == "identities",
                      do: "border-accent-500 text-accent-600",
                      else:
                        "border-transparent text-neutral-500 hover:text-neutral-700 hover:border-neutral-300"
                    )
                  ]}
                >
                  <.icon name="hero-identification" class="w-5 h-5" /> External Identities
                </button>
                <button
                  type="button"
                  phx-click="change_tab"
                  phx-value-tab="client_sessions"
                  class={[
                    "py-4 px-1 border-b-2 font-medium text-sm flex items-center gap-2",
                    if(@active_tab == "client_sessions",
                      do: "border-accent-500 text-accent-600",
                      else:
                        "border-transparent text-neutral-500 hover:text-neutral-700 hover:border-neutral-300"
                    )
                  ]}
                >
                  <.icon name="hero-device-phone-mobile" class="w-5 h-5" /> Client Sessions
                </button>
                <button
                  type="button"
                  phx-click="change_tab"
                  phx-value-tab="portal_sessions"
                  class={[
                    "py-4 px-1 border-b-2 font-medium text-sm flex items-center gap-2",
                    if(@active_tab == "portal_sessions",
                      do: "border-accent-500 text-accent-600",
                      else:
                        "border-transparent text-neutral-500 hover:text-neutral-700 hover:border-neutral-300"
                    )
                  ]}
                >
                  <.icon name="hero-computer-desktop" class="w-5 h-5" /> Portal Sessions
                </button>
              <% else %>
                <button
                  type="button"
                  phx-click="change_tab"
                  phx-value-tab="tokens"
                  class={[
                    "py-4 px-1 border-b-2 font-medium text-sm flex items-center gap-2",
                    if(@active_tab == "tokens",
                      do: "border-accent-500 text-accent-600",
                      else:
                        "border-transparent text-neutral-500 hover:text-neutral-700 hover:border-neutral-300"
                    )
                  ]}
                >
                  <.icon name="hero-key" class="w-5 h-5" /> Tokens
                </button>
              <% end %>
              <button
                type="button"
                phx-click="change_tab"
                phx-value-tab="groups"
                class={[
                  "py-4 px-1 border-b-2 font-medium text-sm flex items-center gap-2",
                  if(@active_tab == "groups",
                    do: "border-accent-500 text-accent-600",
                    else:
                      "border-transparent text-neutral-500 hover:text-neutral-700 hover:border-neutral-300"
                  )
                ]}
              >
                <.icon name="hero-user-group" class="w-5 h-5" /> Groups
              </button>
            </nav>
          </div>
          <!-- Identities Tab -->
          <%= if @actor.type != :service_account and @active_tab == "identities" do %>
            <div class="max-h-96 overflow-y-auto border border-neutral-200 rounded-lg">
              <%= if @identities == [] do %>
                <div class="text-center text-neutral-500 p-8">No external identities to display.</div>
              <% else %>
                <div class="divide-y divide-neutral-200">
                  <div :for={identity <- @identities} class="p-4 hover:bg-neutral-50">
                    <div class="flex items-start justify-between gap-4">
                      <div class="flex-1 space-y-3">
                        <div class="flex items-center gap-2 min-w-0">
                          <.provider_icon
                            type={provider_type_from_issuer(identity.issuer)}
                            class="w-5 h-5 flex-shrink-0"
                          />
                          <div
                            class="font-medium text-sm text-neutral-900 truncate"
                            title={identity.issuer}
                          >
                            {identity.issuer}
                          </div>
                        </div>

                        <div class="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
                          <div :if={identity.directory_id}>
                            <span class="text-xs uppercase text-neutral-500">Directory</span>
                            <div class="text-neutral-900 truncate" title={identity.directory_name}>
                              {identity.directory_name}
                            </div>
                          </div>

                          <div>
                            <span class="text-xs uppercase text-neutral-500">
                              Identity Provider ID
                            </span>
                            <div
                              class="text-neutral-900 truncate"
                              title={extract_idp_id(identity.idp_id)}
                            >
                              {extract_idp_id(identity.idp_id)}
                            </div>
                          </div>

                          <div :if={identity.email}>
                            <span class="text-xs uppercase text-neutral-500">Email</span>
                            <div class="text-neutral-900 truncate" title={identity.email}>
                              {identity.email}
                            </div>
                          </div>

                          <div :if={identity.name}>
                            <span class="text-xs uppercase text-neutral-500">Name</span>
                            <div class="text-neutral-900 truncate" title={identity.name}>
                              {identity.name}
                            </div>
                          </div>

                          <div :if={identity.given_name}>
                            <span class="text-xs uppercase text-neutral-500">Given Name</span>
                            <div class="text-neutral-900 truncate" title={identity.given_name}>
                              {identity.given_name}
                            </div>
                          </div>

                          <div :if={identity.family_name}>
                            <span class="text-xs uppercase text-neutral-500">Family Name</span>
                            <div class="text-neutral-900 truncate" title={identity.family_name}>
                              {identity.family_name}
                            </div>
                          </div>

                          <div :if={identity.middle_name}>
                            <span class="text-xs uppercase text-neutral-500">Middle Name</span>
                            <div class="text-neutral-900 truncate" title={identity.middle_name}>
                              {identity.middle_name}
                            </div>
                          </div>

                          <div :if={identity.nickname}>
                            <span class="text-xs uppercase text-neutral-500">Nickname</span>
                            <div class="text-neutral-900 truncate" title={identity.nickname}>
                              {identity.nickname}
                            </div>
                          </div>

                          <div :if={identity.preferred_username}>
                            <span class="text-xs uppercase text-neutral-500">
                              Preferred Username
                            </span>
                            <div
                              class="text-neutral-900 truncate"
                              title={identity.preferred_username}
                            >
                              {identity.preferred_username}
                            </div>
                          </div>

                          <div :if={identity.profile}>
                            <span class="text-xs uppercase text-neutral-500">Profile</span>
                            <div class="text-neutral-900 truncate" title={identity.profile}>
                              {identity.profile}
                            </div>
                          </div>

                          <div :if={identity.last_synced_at}>
                            <span class="text-xs uppercase text-neutral-500">Last Synced</span>
                            <div class="text-neutral-900">
                              <.relative_datetime datetime={identity.last_synced_at} />
                            </div>
                          </div>

                          <div :if={identity.updated_at}>
                            <span class="text-xs uppercase text-neutral-500">Updated</span>
                            <div class="text-neutral-900">
                              <.relative_datetime datetime={identity.updated_at} />
                            </div>
                          </div>
                        </div>
                      </div>

                      <button
                        type="button"
                        phx-click="delete_identity"
                        phx-value-id={identity.id}
                        class="text-red-600 hover:text-red-800 flex-shrink-0"
                        data-confirm="Are you sure you want to delete this identity?"
                      >
                        <.icon name="hero-trash" class="w-5 h-5" />
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
          <!-- Client Sessions Tab (Users only) -->
          <%= if @actor.type != :service_account and @active_tab == "client_sessions" do %>
            <div class="max-h-96 overflow-y-auto border border-neutral-200 rounded-lg">
              <%= if @tokens == [] do %>
                <div class="text-center text-neutral-500 p-8">
                  No client sessions to display.
                </div>
              <% else %>
                <div class="divide-y divide-neutral-200">
                  <div :for={token <- @tokens} class="p-4 hover:bg-neutral-50">
                    <div class="flex items-center gap-4">
                      <.ping_icon
                        color={if token.online?, do: "success", else: "danger"}
                        title={if token.online?, do: "Online", else: "Offline"}
                      />
                      <.icon
                        name={client_os_icon_name(token.last_seen_user_agent)}
                        class="w-6 h-6 flex-shrink-0"
                      />
                      <div class="flex-1 grid grid-cols-[auto_auto_1fr] gap-x-4 text-sm">
                        <div class="w-28">
                          <span class="text-xs uppercase text-neutral-500">Last connected</span>
                          <div class="text-neutral-900">
                            <.relative_datetime datetime={token.last_seen_at} />
                          </div>
                        </div>
                        <div class="w-20">
                          <span class="text-xs uppercase text-neutral-500">Expires</span>
                          <div class="text-neutral-900">
                            <.relative_datetime datetime={token.expires_at} />
                          </div>
                        </div>
                        <div>
                          <span class="text-xs uppercase text-neutral-500">Location</span>
                          <div class="text-neutral-900">
                            <%= if token_location(token) || token.last_seen_remote_ip do %>
                              <div :if={token_location(token)}>{token_location(token)}</div>
                              <div :if={token.last_seen_remote_ip}>
                                {token.last_seen_remote_ip}
                              </div>
                            <% else %>
                              -
                            <% end %>
                          </div>
                        </div>
                      </div>
                      <button
                        type="button"
                        phx-click="delete_token"
                        phx-value-id={token.id}
                        class="text-red-600 hover:text-red-800"
                        data-confirm="Are you sure you want to delete this client session?"
                      >
                        <.icon name="hero-trash" class="w-5 h-5" />
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
          <!-- Tokens Tab (Service Accounts only) -->
          <%= if @actor.type == :service_account and @active_tab == "tokens" do %>
            <div class="max-h-96 overflow-y-auto border border-neutral-200 rounded-lg">
              <%= if @tokens == [] do %>
                <div class="text-center text-neutral-500 p-8">
                  No tokens to display.
                </div>
              <% else %>
                <div class="divide-y divide-neutral-200">
                  <div :for={token <- @tokens} class="p-4 hover:bg-neutral-50">
                    <div class="flex items-center gap-4">
                      <.ping_icon
                        color={if token.online?, do: "success", else: "danger"}
                        title={if token.online?, do: "Online", else: "Offline"}
                      />
                      <.icon
                        name={client_os_icon_name(token.last_seen_user_agent)}
                        class="w-6 h-6 flex-shrink-0"
                      />
                      <div class="flex-1 grid grid-cols-[auto_auto_1fr] gap-x-4 text-sm">
                        <div class="w-28">
                          <span class="text-xs uppercase text-neutral-500">Last used</span>
                          <div class="text-neutral-900">
                            <.relative_datetime datetime={token.last_seen_at} />
                          </div>
                        </div>
                        <div class="w-20">
                          <span class="text-xs uppercase text-neutral-500">Expires</span>
                          <div class="text-neutral-900">
                            <.relative_datetime datetime={token.expires_at} />
                          </div>
                        </div>
                        <div>
                          <span class="text-xs uppercase text-neutral-500">Location</span>
                          <div class="text-neutral-900">
                            <%= if token_location(token) || token.last_seen_remote_ip do %>
                              <div :if={token_location(token)}>{token_location(token)}</div>
                              <div :if={token.last_seen_remote_ip}>
                                {token.last_seen_remote_ip}
                              </div>
                            <% else %>
                              -
                            <% end %>
                          </div>
                        </div>
                      </div>
                      <button
                        type="button"
                        phx-click="delete_token"
                        phx-value-id={token.id}
                        class="text-red-600 hover:text-red-800"
                        data-confirm="Are you sure you want to delete this token?"
                      >
                        <.icon name="hero-trash" class="w-5 h-5" />
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
          <!-- Portal Sessions Tab (Users only) -->
          <%= if @actor.type != :service_account and @active_tab == "portal_sessions" do %>
            <div class="max-h-96 overflow-y-auto border border-neutral-200 rounded-lg">
              <%= if @sessions == [] do %>
                <div class="text-center text-neutral-500 p-8">
                  No sessions to display.
                </div>
              <% else %>
                <div class="divide-y divide-neutral-200">
                  <div :for={session <- @sessions} class="p-4 hover:bg-neutral-50">
                    <div class="flex items-center gap-4">
                      <.ping_icon
                        color={if session.online?, do: "success", else: "danger"}
                        title={if session.online?, do: "Online", else: "Offline"}
                      />
                      <.icon
                        name={session_user_agent_icon(session.user_agent)}
                        class="w-6 h-6 flex-shrink-0"
                      />
                      <div class="flex-1 grid grid-cols-[auto_auto_1fr] gap-x-4 text-sm">
                        <div class="w-28">
                          <span class="text-xs uppercase text-neutral-500">Signed in</span>
                          <div class="text-neutral-900">
                            <.relative_datetime datetime={session.inserted_at} />
                          </div>
                        </div>
                        <div class="w-20">
                          <span class="text-xs uppercase text-neutral-500">Expires</span>
                          <div class="text-neutral-900">
                            <.relative_datetime datetime={session.expires_at} />
                          </div>
                        </div>
                        <div>
                          <span class="text-xs uppercase text-neutral-500">Location</span>
                          <div class="text-neutral-900">
                            <%= if session_location(session) || session.remote_ip do %>
                              <div :if={session_location(session)}>{session_location(session)}</div>
                              <div :if={session.remote_ip}>
                                {session.remote_ip}
                              </div>
                            <% else %>
                              -
                            <% end %>
                          </div>
                        </div>
                      </div>
                      <button
                        type="button"
                        phx-click="delete_session"
                        phx-value-id={session.id}
                        class="text-red-600 hover:text-red-800"
                        data-confirm="Are you sure you want to delete this session?"
                      >
                        <.icon name="hero-trash" class="w-5 h-5" />
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
          <!-- Groups Tab -->
          <%= if @active_tab == "groups" do %>
            <div class="max-h-96 overflow-y-auto border border-neutral-200 rounded-lg">
              <%= if @groups == [] do %>
                <div class="text-center text-neutral-500 p-8">No groups to display.</div>
              <% else %>
                <div class="divide-y divide-neutral-200">
                  <%= for {section, section_groups} <- groups_by_section(@groups) do %>
                    <div class="bg-neutral-50 px-4 py-2 border-b border-neutral-200">
                      <span class="text-xs font-semibold text-neutral-600 uppercase">
                        {section}
                      </span>
                    </div>
                    <.link
                      :for={group <- section_groups}
                      navigate={
                        ~p"/#{@account}/groups/#{group.id}?#{[return_to: ~p"/#{@account}/actors/#{@actor.id}"]}"
                      }
                      class="block p-4 hover:bg-neutral-50"
                    >
                      <div class="flex items-center gap-3">
                        <.provider_icon
                          type={provider_type_from_group(group)}
                          class="w-5 h-5 flex-shrink-0"
                        />
                        <div class="flex-1 min-w-0">
                          <span class="flex items-center gap-2">
                            <span class="font-medium text-sm text-neutral-900 truncate">
                              {group.name}
                            </span>
                            <span
                              :if={group.entity_type == :org_unit}
                              class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-neutral-100 text-neutral-600"
                              title="Organizational Unit"
                            >
                              OU
                            </span>
                          </span>
                        </div>
                        <.icon name="hero-chevron-right" class="w-5 h-5 text-neutral-400" />
                      </div>
                    </.link>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </:body>
    </.modal>

    <!-- Edit Actor Modal -->
    <.modal
      :if={@live_action == :edit}
      id="edit-actor-modal"
      on_close="close_modal"
      on_back={JS.patch(~p"/#{@account}/actors/#{@actor}?#{@query_params}")}
      confirm_disabled={not @form.source.valid?}
    >
      <:title>Edit {@actor.name}</:title>
      <:body>
        <.form id="actor-form" for={@form} phx-change="validate" phx-submit="save">
          <div class="space-y-6">
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
              <.input
                field={@form[:type]}
                label="Role"
                type="select"
                options={[
                  {"User", :account_user},
                  {"Admin", :account_admin_user}
                ]}
                disabled={@is_last_admin}
                required
              />
              <p :if={@is_last_admin} class="mt-1 text-xs text-orange-600">
                Cannot change role. At least one admin must remain in the account.
              </p>
            </div>

            <div
              :if={@form[:type].value != :service_account}
              id="edit-allow-email-otp-checkbox"
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
      <:back_button>Back</:back_button>
      <:confirm_button form="actor-form" type="submit">Save</:confirm_button>
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
                class="block w-full rounded-lg border-neutral-300 focus:border-accent-400 focus:ring focus:ring-accent-200 focus:ring-opacity-50"
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
        <.icon name="hero-server" class={@class} />
      <% :account_admin_user -> %>
        <.icon name="hero-shield-check" class={@class} />
      <% _ -> %>
        <.icon name="hero-user" class={@class} />
    <% end %>
    """
  end

  defp actor_type_icon_with_badge(assigns) do
    ~H"""
    <div class="relative inline-flex">
      <div class={[
        "inline-flex items-center justify-center w-8 h-8 rounded-full",
        actor_type_icon_bg_color(@actor.type)
      ]}>
        <%= case @actor.type do %>
          <% :service_account -> %>
            <.icon name="hero-server" class={"w-5 h-5 #{actor_type_icon_text_color(@actor.type)}"} />
          <% :account_admin_user -> %>
            <.icon
              name="hero-shield-check"
              class={"w-5 h-5 #{actor_type_icon_text_color(@actor.type)}"}
            />
          <% _ -> %>
            <.icon name="hero-user" class={"w-5 h-5 #{actor_type_icon_text_color(@actor.type)}"} />
        <% end %>
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

  defp actor_type_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium uppercase",
      actor_type_badge_color(@actor.type)
    ]}>
      {actor_display_type(@actor)}
    </span>
    """
  end

  defp actor_type_icon_bg_color(:service_account), do: "bg-blue-100"
  defp actor_type_icon_bg_color(:account_admin_user), do: "bg-purple-100"
  defp actor_type_icon_bg_color(_), do: "bg-neutral-100"

  defp actor_type_icon_text_color(:service_account), do: "text-blue-800"
  defp actor_type_icon_text_color(:account_admin_user), do: "text-purple-800"
  defp actor_type_icon_text_color(_), do: "text-neutral-800"

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

  defp group_section_name(%{directory_name: name}) when not is_nil(name),
    do: "Synced from #{name}"

  defp group_section_name(%{idp_id: idp_id}) when not is_nil(idp_id),
    do: "Synced from Unknown"

  defp group_section_name(_), do: "Firezone"

  defp groups_by_section(groups) do
    groups
    |> Enum.group_by(&group_section_name/1)
    |> Enum.sort_by(fn {section, _} ->
      case section do
        "Firezone" -> 0
        "Synced from Unknown" -> 2
        _ -> 1
      end
    end)
  end

  # Utility helpers
  defp handle_success(socket, message) do
    socket
    |> put_flash(:success, message)
    |> reload_live_table!("actors")
    |> close_modal()
  end

  # Navigation helpers
  defp row_patch_path(actor, query_params) do
    ~p"/#{actor.account_id}/actors/#{actor.id}?#{query_params}"
  end

  defp close_modal(socket) do
    if return_to = handle_return_to(socket) do
      push_navigate(socket, to: return_to)
    else
      push_patch(socket, to: ~p"/#{socket.assigns.account}/actors?#{socket.assigns.query_params}")
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

  defp token_location(token) do
    cond do
      token.last_seen_remote_ip_location_city && token.last_seen_remote_ip_location_region ->
        "#{token.last_seen_remote_ip_location_city}, #{token.last_seen_remote_ip_location_region}"

      token.last_seen_remote_ip_location_region ->
        token.last_seen_remote_ip_location_region

      true ->
        nil
    end
  end

  # Helper functions for session display
  defp session_user_agent_icon(user_agent) when is_binary(user_agent) do
    detect_os_icon(user_agent) || "hero-computer-desktop"
  end

  defp session_user_agent_icon(_), do: "hero-computer-desktop"

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
          name: :directory_id,
          title: "Directory",
          type: {:string, :select},
          values: &directory_values/1,
          fun: &filter_by_directory/2
        },
        %Filter{
          name: :name_or_email,
          title: "Name or Email",
          type: {:string, :websearch},
          fun: &filter_by_name_or_email/2
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
        |> Safe.scoped(subject)
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
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def get_actor!(id, subject) do
      from(a in Actor, as: :actors)
      |> where([actors: a], a.id == ^id)
      |> where([actors: a], a.type != :api_client)
      |> Safe.scoped(subject)
      |> Safe.one!()
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
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def other_enabled_admins_exist?(account_id, actor_id, subject) do
      from(a in Actor,
        where: a.account_id == ^account_id,
        where: a.type == :account_admin_user,
        where: a.id != ^actor_id,
        where: is_nil(a.disabled_at)
      )
      |> Safe.scoped(subject)
      |> Safe.exists?()
    end

    def get_client_tokens_for_actor(actor_id, subject) do
      from(c in ClientToken, as: :client_tokens)
      |> where([client_tokens: c], c.actor_id == ^actor_id)
      |> order_by([client_tokens: c], desc: c.inserted_at)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Presence.Clients.preload_client_tokens_presence()
    end

    def get_identity_by_id(identity_id, subject) do
      from(i in ExternalIdentity, as: :identities)
      |> where([identities: i], i.id == ^identity_id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    def get_client_token_by_id(token_id, subject) do
      from(c in ClientToken, as: :client_tokens)
      |> where([client_tokens: c], c.id == ^token_id)
      |> Safe.scoped(subject)
      |> Safe.one()
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
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Presence.PortalSessions.preload_portal_sessions_presence()
    end

    def get_portal_session_by_id(session_id, subject) do
      from(ps in PortalSession, as: :portal_sessions)
      |> where([portal_sessions: ps], ps.id == ^session_id)
      |> Safe.scoped(subject)
      |> Safe.one()
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
      |> Safe.scoped(subject)
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
  end
end
