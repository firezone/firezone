defmodule Web.Actors do
  use Web, :live_view

  alias __MODULE__.Query

  alias Domain.{
    Actors,
    Tokens,
    Safe
  }

  import Ecto.Changeset

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Actors")
      |> assign_live_table("actors",
        query_module: Query,
        sortable_fields: [
          {:actors, :name},
          {:actors, :email}
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
    changeset = actor_changeset(%Actors.Actor{}, %{type: :account_user})
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
    actor = %Actors.Actor{type: :service_account}
    changeset = actor_changeset(actor, %{})
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
    actor = Query.get_actor!(id, socket.assigns.subject)

    # Load identities and tokens
    identities = Query.get_identities_for_actor(actor.id, socket.assigns.subject)
    tokens = Query.get_tokens_for_actor(actor.id, socket.assigns.subject)

    socket = handle_live_tables_params(socket, params, uri)

    socket =
      socket
      |> assign(
        actor: actor,
        active_tab: "identities",
        identities: identities,
        tokens: tokens
      )
      |> assign_new(:created_token, fn -> nil end)

    {:noreply, socket}
  end

  # Add Token Modal
  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :add_token}} = socket) do
    actor = Query.get_actor!(id, socket.assigns.subject)
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
    actor = Query.get_actor!(id, socket.assigns.subject)
    socket = handle_live_tables_params(socket, params, uri)

    if is_editable_actor?(actor) do
      changeset = actor_changeset(actor, %{})

      {:noreply,
       assign(socket,
         actor: actor,
         form: to_form(changeset)
       )}
    else
      {:noreply,
       socket
       |> put_flash(:error, "This actor cannot be edited")
       |> push_patch(to: ~p"/#{socket.assigns.account}/actors/show/#{id}?#{query_params(uri)}")}
    end
  end

  # Default handler
  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)
    {:noreply, socket}
  end

  def handle_event(event, params, socket) when event in ["paginate", "order_by", "filter"],
    do: handle_live_table_event(event, params, socket)

  def handle_event("close_modal", _params, socket) do
    {:noreply, close_modal(socket)}
  end

  def handle_event("select_type", %{"type" => type}, socket) do
    path =
      case type do
        "user" ->
          ~p"/#{socket.assigns.account}/actors/add_user?#{query_params(socket.assigns.uri)}"

        "service_account" ->
          ~p"/#{socket.assigns.account}/actors/add_service_account?#{query_params(socket.assigns.uri)}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("validate", %{"actor" => attrs} = params, socket) do
    # Use form data which has type already set, or actor from assigns for edit
    actor = socket.assigns[:actor] || socket.assigns.form.data

    changeset =
      actor
      |> actor_changeset(attrs)
      |> Map.put(:action, :validate)

    # Preserve token_expiration for service account form
    token_expiration =
      Map.get(params, "token_expiration", socket.assigns[:token_expiration] || "")

    {:noreply, assign(socket, form: to_form(changeset), token_expiration: token_expiration)}
  end

  def handle_event("create_user", %{"actor" => attrs}, socket) do
    attrs = Map.put(attrs, "type", "account_user")
    changeset = actor_changeset(%Actors.Actor{}, attrs)

    case create_actor(changeset, socket.assigns.subject) do
      {:ok, actor} ->
        params = query_params(socket.assigns.uri)

        socket =
          socket
          |> put_flash(:info, "User created successfully")
          |> reload_live_table!("actors")
          |> push_patch(to: ~p"/#{socket.assigns.account}/actors/show/#{actor.id}?#{params}")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("create_service_account", %{"actor" => attrs} = params, socket) do
    attrs = Map.put(attrs, "type", "service_account")
    changeset = actor_changeset(%Actors.Actor{type: :service_account}, attrs)
    token_expiration = Map.get(params, "token_expiration")

    result =
      Domain.Repo.transact(fn ->
        with {:ok, actor} <- create_actor(changeset, socket.assigns.subject),
             {:ok, token_result} <-
               maybe_create_token(actor, token_expiration, socket.assigns.subject) do
          {:ok, {actor, token_result}}
        end
      end)

    case result do
      {:ok, {actor, nil}} ->
        params = query_params(socket.assigns.uri)

        socket =
          socket
          |> put_flash(:info, "Service account created successfully")
          |> reload_live_table!("actors")
          |> push_patch(to: ~p"/#{socket.assigns.account}/actors/show/#{actor.id}?#{params}")

        {:noreply, socket}

      {:ok, {actor, {_token, encoded_token}}} ->
        params = query_params(socket.assigns.uri)

        socket =
          socket
          |> put_flash(:info, "Service account created successfully")
          |> reload_live_table!("actors")
          |> assign(created_token: encoded_token)
          |> push_patch(to: ~p"/#{socket.assigns.account}/actors/show/#{actor.id}?#{params}")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("save", %{"actor" => attrs}, socket) do
    if is_editable_actor?(socket.assigns.actor) do
      changeset = actor_changeset(socket.assigns.actor, attrs)

      case update_actor(changeset, socket.assigns.subject) do
        {:ok, actor} ->
          params = query_params(socket.assigns.uri)

          socket =
            socket
            |> put_flash(:info, "Actor updated successfully")
            |> reload_live_table!("actors")
            |> push_patch(to: ~p"/#{socket.assigns.account}/actors/show/#{actor.id}?#{params}")

          {:noreply, socket}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "This actor cannot be edited")
       |> close_modal()}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = Query.get_actor!(id, socket.assigns.subject)

    case delete_actor(actor, socket.assigns.subject) do
      {:ok, _actor} ->
        {:noreply, handle_success(socket, "Actor deleted successfully")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to delete this actor")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete actor")}
    end
  end

  def handle_event("disable", %{"id" => id}, socket) do
    actor = Query.get_actor!(id, socket.assigns.subject)

    case disable_actor(actor, socket.assigns.subject) do
      {:ok, _actor} ->
        socket = reload_live_table!(socket, "actors")
        {:noreply, put_flash(socket, :info, "Actor disabled successfully")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You are not authorized to disable this actor")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to disable actor")}
    end
  end

  def handle_event("enable", %{"id" => id}, socket) do
    actor = Query.get_actor!(id, socket.assigns.subject)

    case enable_actor(actor, socket.assigns.subject) do
      {:ok, _actor} ->
        socket = reload_live_table!(socket, "actors")
        {:noreply, put_flash(socket, :info, "Actor enabled successfully")}

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

    case create_token_for_actor(actor, token_expiration, socket.assigns.subject) do
      {:ok, encoded_token} ->
        params = query_params(socket.assigns.uri)

        socket =
          socket
          |> assign(created_token: encoded_token)
          |> push_patch(to: ~p"/#{socket.assigns.account}/actors/show/#{actor.id}?#{params}")

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create token")}
    end
  end

  def handle_event("delete_token", %{"id" => token_id}, socket) do
    case Tokens.fetch_token_by_id(token_id, socket.assigns.subject) do
      {:ok, token} ->
        case Tokens.delete_token(token, socket.assigns.subject) do
          {:ok, _} ->
            # Reload tokens for the actor
            tokens = Query.get_tokens_for_actor(socket.assigns.actor.id, socket.assigns.subject)
            socket = assign(socket, tokens: tokens)
            {:noreply, put_flash(socket, :info, "Token deleted successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete token")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Token not found")}
    end
  end

  def handle_event("delete_identity", %{"id" => identity_id}, socket) do
    case Domain.Auth.fetch_identity_by_id(identity_id, socket.assigns.subject) do
      {:ok, identity} ->
        case Domain.Auth.delete_identity(identity, socket.assigns.subject) do
          {:ok, _} ->
            # Reload identities for the actor
            identities =
              Query.get_identities_for_actor(socket.assigns.actor.id, socket.assigns.subject)

            socket = assign(socket, identities: identities)
            {:noreply, put_flash(socket, :info, "Identity deleted successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete identity")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Identity not found")}
    end
  end

  def handle_actors_update!(socket, list_opts) do
    with {:ok, actors, metadata} <- Query.list_actors(socket.assigns.subject, list_opts) do
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
        <.add_button navigate={~p"/#{@account}/actors/add?#{query_params(@uri)}"}>
          Add Actor
        </.add_button>
      </:action>

      <:help>
        Actors are the people and services that can access your Resources.
      </:help>

      <:content>
        <.flash_group flash={@flash} />
        <.live_table
          id="actors"
          rows={@actors}
          row_id={&"actor-#{&1.id}"}
          row_patch={&row_patch_path(&1, @uri)}
          filters={@filters_by_table_id["actors"]}
          filter={@filter_form_by_table_id["actors"]}
          ordered_by={@order_by_table_id["actors"]}
          metadata={@actors_metadata}
        >
          <:col :let={actor} class="w-8">
            <.actor_type_icon actor={actor} />
          </:col>
          <:col :let={actor} field={{:actors, :name}} label="name" class="w-3/12">
            {actor.name}
          </:col>
          <:col :let={actor} field={{:actors, :email}} label="email" class="w-3/12">
            <span class="block truncate" title={actor.email}>
              {actor.email || "-"}
            </span>
          </:col>
          <:col :let={actor} label="type" class="w-2/12">
            <.actor_type_badge actor={actor} />
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

            <.input
              field={@form[:allow_email_sign_in]}
              label="Allow user to sign in via Email"
              type="checkbox"
            />
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
              <span>{actor_display_type(@actor)}: {@actor.name}</span>
              <.actor_type_badge actor={@actor} />
            </div>
            <div class="text-sm font-normal text-neutral-600">{@actor.email}</div>
          </div>
        </div>
      </:title>
      <:body>
        <.flash_group flash={@flash} />

        <%= if @created_token do %>
          <div
            id="created-token-display"
            class="bg-green-50 border border-green-200 rounded-lg p-4 mb-4"
            phx-hook="CopyClipboard"
          >
            <div class="flex items-start gap-3">
              <.icon name="hero-check-circle" class="w-5 h-5 text-green-600 flex-shrink-0 mt-0.5" />
              <div class="flex-1">
                <h4 class="text-sm font-semibold text-green-900 mb-2">Token Created Successfully</h4>
                <p class="text-sm text-green-800 mb-3">
                  Save this token now. You won't be able to see it again!
                </p>
                <div class="relative">
                  <code
                    id="created-token-display-code"
                    class="block bg-white border border-green-300 rounded px-3 py-2 pr-24 text-sm font-mono text-neutral-900 break-all"
                  >
                    {@created_token}
                  </code>
                  <button
                    type="button"
                    data-copy-to-clipboard-target="created-token-display-code"
                    data-copy-to-clipboard-content-type="innerHTML"
                    data-copy-to-clipboard-html-entities="true"
                    class="absolute top-1 right-1 px-3 py-1.5 text-sm font-medium text-green-700 bg-white border border-green-300 hover:bg-green-50 rounded inline-flex items-center"
                  >
                    <span id="created-token-display-default-message" class="inline-flex items-center">
                      <.icon name="hero-clipboard-document" class="w-4 h-4" />
                    </span>
                    <span
                      id="created-token-display-success-message"
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
            <div class="flex items-center justify-between mb-3">
              <div class="text-sm text-neutral-600">
                Last synced: <.relative_datetime datetime={@actor.last_synced_at} />
              </div>
              <.popover placement="bottom-end" trigger="click">
                <:target>
                  <button
                    type="button"
                    class="text-neutral-500 hover:text-neutral-700 focus:outline-none"
                  >
                    <.icon name="hero-ellipsis-horizontal" class="w-6 h-6" />
                  </button>
                </:target>
                <:content>
                  <div class="py-1">
                    <.link
                      navigate={~p"/#{@account}/actors/edit/#{@actor.id}?#{query_params(@uri)}"}
                      class="px-3 py-2 text-sm text-neutral-800 rounded-lg hover:bg-neutral-100 flex items-center gap-2 whitespace-nowrap"
                    >
                      <.icon name="hero-pencil" class="w-4 h-4" /> Edit
                    </.link>
                    <button
                      :if={not Actors.actor_disabled?(@actor)}
                      type="button"
                      phx-click="disable"
                      phx-value-id={@actor.id}
                      class="w-full px-3 py-2 text-sm text-orange-600 rounded-lg hover:bg-neutral-100 flex items-center gap-2 border-0 bg-transparent whitespace-nowrap"
                    >
                      <.icon name="hero-lock-closed" class="w-4 h-4" /> Disable
                    </button>
                    <button
                      :if={Actors.actor_disabled?(@actor)}
                      type="button"
                      phx-click="enable"
                      phx-value-id={@actor.id}
                      class="w-full px-3 py-2 text-sm text-green-600 rounded-lg hover:bg-neutral-100 flex items-center gap-2 border-0 bg-transparent whitespace-nowrap"
                    >
                      <.icon name="hero-lock-open" class="w-4 h-4" /> Enable
                    </button>
                    <button
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
          <%= if @actor.type != :service_account do %>
            <div class="border-b border-neutral-200">
              <nav class="-mb-px flex space-x-8">
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
                  <.icon name="hero-identification" class="w-5 h-5" /> Identities
                </button>
                <button
                  type="button"
                  phx-click="change_tab"
                  phx-value-tab="sessions"
                  class={[
                    "py-4 px-1 border-b-2 font-medium text-sm flex items-center gap-2",
                    if(@active_tab == "sessions",
                      do: "border-accent-500 text-accent-600",
                      else:
                        "border-transparent text-neutral-500 hover:text-neutral-700 hover:border-neutral-300"
                    )
                  ]}
                >
                  <.icon name="hero-computer-desktop" class="w-5 h-5" /> Sessions
                </button>
              </nav>
            </div>
          <% end %>
          <!-- Identities Tab -->
          <%= if @actor.type != :service_account and @active_tab == "identities" do %>
            <div class="max-h-96 overflow-y-auto border border-neutral-200 rounded-lg">
              <%= if @identities == [] do %>
                <div class="text-center text-neutral-500 p-8">No identities to display.</div>
              <% else %>
                <div class="divide-y divide-neutral-200">
                  <div
                    :for={identity <- @identities}
                    class="p-4 hover:bg-neutral-50 flex items-center justify-between"
                  >
                    <div class="flex-1">
                      <div class="flex items-center gap-2">
                        <.icon name="hero-user-circle" class="w-5 h-5 text-neutral-400" />
                        <div>
                          <div class="font-medium text-sm text-neutral-900">
                            {identity.issuer}
                          </div>
                          <div class="text-xs text-neutral-500">
                            {identity.idp_id}
                          </div>
                        </div>
                      </div>
                    </div>
                    <button
                      type="button"
                      phx-click="delete_identity"
                      phx-value-id={identity.id}
                      class="text-red-600 hover:text-red-800"
                      data-confirm="Are you sure you want to delete this identity?"
                    >
                      <.icon name="hero-trash" class="w-5 h-5" />
                    </button>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
          <!-- Sessions/Tokens Tab -->
          <%= if @actor.type == :service_account or @active_tab == "sessions" do %>
            <div>
              <%= if @actor.type == :service_account do %>
                <div class="flex justify-between items-center mb-4">
                  <h3 class="text-sm font-semibold text-neutral-900">Tokens</h3>
                  <.add_button navigate={
                    ~p"/#{@account}/actors/show/#{@actor.id}/add_token?#{query_params(@uri)}"
                  }>
                    Add Token
                  </.add_button>
                </div>
              <% end %>

              <div class="max-h-96 overflow-y-auto border border-neutral-200 rounded-lg">
                <%= if @tokens == [] do %>
                  <div class="text-center text-neutral-500 p-8">
                    {if @actor.type == :service_account,
                      do: "No tokens to display.",
                      else: "No sessions to display."}
                  </div>
                <% else %>
                  <div class="divide-y divide-neutral-200">
                    <div
                      :for={token <- @tokens}
                      class="p-4 hover:bg-neutral-50 flex items-center justify-between"
                    >
                      <div class="flex-1 grid gap-4 grid-cols-3">
                        <div>
                          <div class="text-xs text-neutral-500">Last used</div>
                          <div class="text-sm text-neutral-900">
                            <.relative_datetime datetime={token.last_seen_at} />
                          </div>
                        </div>
                        <div>
                          <div class="text-xs text-neutral-500">Location</div>
                          <div class="text-sm text-neutral-900 flex items-center gap-2">
                            <%= if token_location(token) do %>
                              <.icon
                                name={token_user_agent_icon(token.last_seen_user_agent)}
                                class="w-4 h-4 flex-shrink-0"
                              />
                              <span>{token_location(token)}</span>
                            <% else %>
                              -
                            <% end %>
                          </div>
                        </div>
                        <div>
                          <div class="text-xs text-neutral-500">Expires</div>
                          <div class="text-sm text-neutral-900">
                            <.relative_datetime datetime={token.expires_at} />
                          </div>
                        </div>
                      </div>
                      <button
                        type="button"
                        phx-click="delete_token"
                        phx-value-id={token.id}
                        class="ml-4 text-red-600 hover:text-red-800"
                        data-confirm="Are you sure you want to delete this token?"
                      >
                        <.icon name="hero-trash" class="w-5 h-5" />
                      </button>
                    </div>
                  </div>
                <% end %>
              </div>
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
              :if={@actor.type != :service_account}
              field={@form[:type]}
              label="Role"
              type="select"
              options={[
                {"User", :account_user},
                {"Admin", :account_admin_user}
              ]}
              required
            />
          </div>
        </.form>
      </:body>
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

  defp actor_type_badge_color(:service_account), do: "bg-blue-100 text-blue-800"
  defp actor_type_badge_color(:account_admin_user), do: "bg-purple-100 text-purple-800"
  defp actor_type_badge_color(_), do: "bg-neutral-100 text-neutral-800"

  defp actor_display_type(%{type: :service_account}), do: "Service Account"
  defp actor_display_type(%{type: :account_admin_user}), do: "Admin"
  defp actor_display_type(%{type: :account_user}), do: "User"
  defp actor_display_type(_), do: "User"

  defp is_editable_actor?(%{last_synced_at: nil}), do: true
  defp is_editable_actor?(_), do: false

  # Utility helpers
  defp handle_success(socket, message) do
    socket
    |> put_flash(:info, message)
    |> reload_live_table!("actors")
    |> close_modal()
  end

  # Navigation helpers
  defp query_params(uri) do
    uri = URI.parse(uri)
    if uri.query, do: URI.decode_query(uri.query), else: %{}
  end

  defp row_patch_path(actor, uri) do
    params = query_params(uri)
    ~p"/#{actor.account_id}/actors/show/#{actor.id}?#{params}"
  end

  defp close_modal(socket) do
    params = query_params(socket.assigns.uri)
    push_patch(socket, to: ~p"/#{socket.assigns.account}/actors?#{params}")
  end

  # Changesets
  defp actor_changeset(actor, attrs) do
    actor
    |> cast(attrs, [:name, :email, :type])
    |> Actors.Actor.changeset()
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

  defp create_token_for_actor(actor, token_expiration, subject) do
    case parse_date_to_datetime(token_expiration) do
      nil ->
        {:error, :invalid_date}

      expires_at ->
        token_attrs = %{
          "type" => "client",
          "actor_id" => actor.id,
          "expires_at" => expires_at,
          "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32)
        }

        case Tokens.create_token(token_attrs, subject) do
          {:ok, token} ->
            encoded_token = Tokens.encode_fragment!(token)
            {:ok, encoded_token}

          error ->
            error
        end
    end
  end

  defp maybe_create_token(_actor, nil, _subject), do: {:ok, nil}
  defp maybe_create_token(_actor, "", _subject), do: {:ok, nil}

  defp maybe_create_token(actor, token_expiration, subject) do
    case parse_date_to_datetime(token_expiration) do
      nil ->
        {:error, :invalid_date}

      expires_at ->
        token_attrs = %{
          "type" => "client",
          "actor_id" => actor.id,
          "expires_at" => expires_at,
          "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32)
        }

        case Tokens.create_token(token_attrs, subject) do
          {:ok, token} ->
            encoded_token = Tokens.encode_fragment!(token)
            {:ok, {token, encoded_token}}

          error ->
            error
        end
    end
  end

  # Helper functions for token/session display
  defp token_user_agent_icon(user_agent) when is_binary(user_agent) do
    cond do
      # Firezone client user agents (e.g., "Windows/10.0", "Mac OS/15.0")
      String.contains?(user_agent, "Windows/") ->
        "os-windows"

      String.contains?(user_agent, "Mac OS/") ->
        "os-macos"

      String.contains?(user_agent, "iOS/") ->
        "os-ios"

      String.contains?(user_agent, "Android/") ->
        "os-android"

      String.contains?(user_agent, "Ubuntu/") ->
        "os-ubuntu"

      String.contains?(user_agent, "Debian/") ->
        "os-debian"

      String.contains?(user_agent, "Manjaro/") ->
        "os-manjaro"

      String.contains?(user_agent, "CentOS/") ->
        "os-linux"

      String.contains?(user_agent, "Fedora/") ->
        "os-linux"

      # Browser user agents (standard Mozilla format)
      String.contains?(user_agent, "iPhone") or String.contains?(user_agent, "iPad") ->
        "os-ios"

      String.contains?(user_agent, "Android") ->
        "os-android"

      String.contains?(user_agent, "Macintosh") or String.contains?(user_agent, "Mac OS X") ->
        "os-macos"

      String.contains?(user_agent, "Windows NT") ->
        "os-windows"

      String.contains?(user_agent, "X11") and String.contains?(user_agent, "Linux") ->
        "os-linux"

      String.contains?(user_agent, "linux") ->
        "os-linux"

      true ->
        "hero-computer-desktop"
    end
  end

  defp token_user_agent_icon(_), do: "hero-computer-desktop"

  defp token_location(token) do
    cond do
      token.last_seen_remote_ip_location_city && token.last_seen_remote_ip_location_region ->
        "#{token.last_seen_remote_ip_location_city}, #{token.last_seen_remote_ip_location_region}"

      token.last_seen_remote_ip_location_region ->
        token.last_seen_remote_ip_location_region

      token.last_seen_remote_ip ->
        to_string(token.last_seen_remote_ip)

      true ->
        nil
    end
  end

  # Database operations using Safe
  defp create_actor(changeset, subject) do
    Safe.scoped(subject)
    |> Safe.insert(changeset)
  end

  defp update_actor(changeset, subject) do
    Safe.scoped(subject)
    |> Safe.update(changeset)
  end

  defp delete_actor(actor, subject) do
    Safe.scoped(subject)
    |> Safe.delete(actor)
  end

  defp disable_actor(actor, subject) do
    changeset = Actors.Actor.Changeset.disable_actor(actor)

    Safe.scoped(subject)
    |> Safe.update(changeset)
  end

  defp enable_actor(actor, subject) do
    changeset = Actors.Actor.Changeset.enable_actor(actor)

    Safe.scoped(subject)
    |> Safe.update(changeset)
  end

  defmodule Query do
    import Ecto.Query
    alias Domain.{Actors, Safe, Auth, Tokens, Repo}

    def list_actors(subject, opts \\ []) do
      with :ok <-
             Auth.ensure_has_permissions(subject, Actors.Authorizer.manage_actors_permission()) do
        all()
        |> Actors.Authorizer.for_subject(subject)
        |> Repo.list(__MODULE__, opts)
      end
    end

    def all do
      from(actors in Actors.Actor, as: :actors)
      |> select_merge([actors: actors], %{
        email:
          fragment(
            "COALESCE(?, (SELECT email FROM auth_identities WHERE actor_id = ? AND email IS NOT NULL ORDER BY inserted_at DESC LIMIT 1))",
            actors.email,
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

    def get_actor!(id, subject) do
      query =
        from(a in Actors.Actor, as: :actors)
        |> where([actors: a], a.id == ^id)

      Safe.scoped(subject) |> Safe.one!(query)
    end

    def get_identities_for_actor(actor_id, subject) do
      query =
        from(i in Auth.Identity, as: :identities)
        |> where([identities: i], i.actor_id == ^actor_id)
        |> order_by([identities: i], desc: i.inserted_at)

      Safe.scoped(subject) |> Safe.all(query)
    end

    def get_tokens_for_actor(actor_id, subject) do
      query =
        from(t in Tokens.Token, as: :tokens)
        |> where([tokens: t], t.actor_id == ^actor_id)
        |> order_by([tokens: t], desc: t.inserted_at)

      Safe.scoped(subject) |> Safe.all(query)
    end
  end
end
