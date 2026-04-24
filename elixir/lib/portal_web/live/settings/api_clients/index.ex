defmodule PortalWeb.Settings.ApiClients.Index do
  use PortalWeb, :live_view

  import Ecto.Changeset,
    only: [change: 1, put_change: 3, cast: 3, validate_required: 2, validate_length: 3]

  import PortalWeb.Settings.ApiClients.Components

  alias Portal.{Actor, APIToken, Authentication}

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def list_actors_with_token(subject) do
      from(a in Portal.Actor, as: :actors)
      |> where([actors: a], a.type == :api_client)
      |> join(:left, [actors: a], t in Portal.APIToken, on: t.actor_id == a.id, as: :tokens)
      |> order_by([actors: a, tokens: t], asc: a.inserted_at, asc: a.id, desc: t.inserted_at)
      |> distinct([actors: a], a.id)
      |> select([actors: a, tokens: t], {a, t})
      |> Safe.scoped(subject, :replica)
      |> Safe.all()
    end

    @spec get_actor!(binary(), any()) :: Portal.Actor.t()
    def get_actor!(id, subject) do
      from(a in Portal.Actor,
        where: a.id == ^id,
        where: a.type == :api_client
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    @spec create_api_token_with_actor(Ecto.Changeset.t(), map(), any()) ::
            {:ok, {Portal.Actor.t(), String.t()}} | {:error, Ecto.Changeset.t()}
    def create_api_token_with_actor(actor_changeset, token_attrs, subject) do
      Safe.transact(fn ->
        with {:ok, actor} <- Safe.scoped(actor_changeset, subject) |> Safe.insert(),
             {:ok, encoded_token} <- Authentication.create_api_token(actor, token_attrs, subject) do
          {:ok, {actor, encoded_token}}
        end
      end)
    end

    @spec delete_token(binary(), any()) :: {:ok, Portal.APIToken.t()} | {:error, atom()}
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

    @spec delete_all_tokens(binary(), any()) :: any()
    def delete_all_tokens(actor_id, subject) do
      from(t in Portal.APIToken, where: t.actor_id == ^actor_id)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
    end
  end

  def mount(_params, _session, socket) do
    if Portal.Account.rest_api_enabled?(socket.assigns.account) do
      actors_with_tokens = Database.list_actors_with_token(socket.assigns.subject)

      socket =
        socket
        |> assign(page_title: "API Tokens")
        |> assign(api_url: Portal.Config.get_env(:portal, :api_external_url))
        |> assign(actors_with_tokens: actors_with_tokens)
        |> assign(selected_actor: nil)
        |> assign(form: nil, encoded_token: nil)
        |> assign(pending_confirm: nil)

      {:ok, socket}
    else
      {:ok, push_navigate(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients/beta")}
    end
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    account = socket.assigns.account

    if Portal.Billing.can_create_api_clients?(account) do
      changeset = build_creation_changeset(%{})

      socket =
        socket
        |> assign(selected_actor: nil, encoded_token: nil)
        |> assign(form: to_form(changeset, as: "api_token"))

      {:noreply, socket}
    else
      socket =
        socket
        |> put_flash(
          :error,
          "You have reached the maximum number of API tokens allowed for your account."
        )
        |> push_patch(to: ~p"/#{account}/settings/api_clients")

      {:noreply, socket}
    end
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :edit}} = socket) do
    actor = Database.get_actor!(id, socket.assigns.subject)
    changeset = actor_name_changeset(actor, %{})

    socket =
      socket
      |> assign(selected_actor: actor, encoded_token: nil)
      |> assign(form: to_form(changeset, as: "actor"))

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket, selected_actor: nil, form: nil, encoded_token: nil, pending_confirm: nil)}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full" phx-window-keydown="handle_keydown" phx-key="Escape">
      <.settings_nav account={@account} current_path={@current_path} />

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex items-center justify-between px-6 py-3 border-b border-[var(--border)] shrink-0">
          <div class="flex items-center gap-2">
            <h2 class="text-xs font-semibold text-[var(--text-primary)]">API Tokens</h2>
            <span class="text-xs text-[var(--text-tertiary)] tabular-nums">
              {length(@actors_with_tokens)}
            </span>
          </div>
          <div class="flex items-center gap-2">
            <.docs_action path="/reference/rest-api" />
            <.link
              patch={~p"/#{@account}/settings/api_clients/new"}
              class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              <.icon name="ri-add-line" class="w-3 h-3" /> Add
            </.link>
          </div>
        </div>

        <div class="flex-1 overflow-auto">
          <%= if Enum.empty?(@actors_with_tokens) do %>
            <div class="flex items-center justify-center h-full">
              <div class="flex flex-col items-center gap-3 py-16">
                <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                  <.icon name="ri-key-line" class="w-3 h-3" />
                </div>
                <div class="text-center">
                  <p class="text-sm font-medium text-[var(--text-primary)]">No API tokens yet</p>
                  <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                    No API tokens have been configured.
                  </p>
                </div>
                <.link
                  patch={~p"/#{@account}/settings/api_clients/new"}
                  class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  <.icon name="ri-add-line" class="w-3 h-3" /> Add an API token
                </.link>
              </div>
            </div>
          <% else %>
            <table class="w-full text-sm border-collapse">
              <thead class="sticky top-0 z-10 bg-[var(--surface-raised)]">
                <tr class="border-b border-[var(--border-strong)]">
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-56">
                    Name
                  </th>
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-28">
                    Status
                  </th>
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-36">
                    Created
                  </th>
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-36">
                    Expires
                  </th>
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-36">
                    Last Used
                  </th>
                  <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] w-36">
                    Last Used IP
                  </th>
                  <th class="px-6 py-2.5 w-10"></th>
                </tr>
              </thead>
              <tbody>
                <.api_client_row
                  :for={{actor, token} <- @actors_with_tokens}
                  account={@account}
                  actor={actor}
                  token={token}
                  pending_confirm={@pending_confirm}
                />
              </tbody>
            </table>
          <% end %>
        </div>
      </div>

    <!-- Creation Panel (:new) -->
      <div
        id="api-client-new-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
          "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
          "transition-transform duration-200 ease-in-out",
          (@live_action == :new && "translate-x-0") || "translate-x-full"
        ]}
      >
        <div :if={@live_action == :new && @form} class="flex flex-col h-full overflow-hidden">
          <!-- Panel header -->
          <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">New API Token</h2>
              <button
                phx-click="close_panel"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="ri-close-line" class="w-4 h-4" />
              </button>
            </div>
          </div>

          <.form
            id="api-token-new-form"
            for={@form}
            phx-change="validate_new"
            phx-submit="create_token"
            class="flex flex-col flex-1 min-h-0 overflow-hidden"
          >
            <!-- Panel body -->
            <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
              <%= if is_nil(@encoded_token) do %>
                <.api_token_creation_form form={@form} />
              <% else %>
                <.api_token_reveal encoded_token={@encoded_token} />
              <% end %>
            </div>

    <!-- Panel footer -->
            <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
              <%= if is_nil(@encoded_token) do %>
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
                  Create Token
                </button>
              <% else %>
                <button
                  type="button"
                  phx-click="close_reveal"
                  class="px-3 py-1.5 text-xs rounded-md font-medium transition-colors bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)]"
                >
                  Done
                </button>
              <% end %>
            </div>
          </.form>
        </div>
      </div>

    <!-- Edit Panel (:edit) -->
      <div
        id="api-client-edit-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
          "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
          "transition-transform duration-200 ease-in-out",
          (@live_action == :edit && "translate-x-0") || "translate-x-full"
        ]}
      >
        <div
          :if={@live_action == :edit && @selected_actor && @form}
          class="flex flex-col h-full overflow-hidden"
        >
          <!-- Panel header -->
          <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">Edit API Token</h2>
              <button
                phx-click="close_panel"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="ri-close-line" class="w-4 h-4" />
              </button>
            </div>
          </div>

          <.form
            id="api-token-edit-form"
            for={@form}
            phx-change="validate_edit"
            phx-submit="update_actor"
            class="flex flex-col flex-1 min-h-0 overflow-hidden"
          >
            <!-- Panel body -->
            <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
              <.input
                label="Name"
                field={@form[:name]}
                placeholder="E.g. 'GitHub Actions' or 'Terraform'"
                phx-debounce="300"
                required
              />
            </div>

    <!-- Panel footer -->
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
                Save
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :token, :any, required: true
  attr :pending_confirm, :any, required: true

  defp api_client_row(assigns) do
    pending = assigns.pending_confirm
    is_pending_delete = pending && pending.id == assigns.actor.id && pending.action == "delete"
    is_pending_toggle = pending && pending.id == assigns.actor.id && pending.action == "toggle"

    assigns =
      assign(assigns, is_pending_delete: is_pending_delete, is_pending_toggle: is_pending_toggle)

    ~H"""
    <tr class={[
      "border-b transition-colors",
      @is_pending_delete && "border-red-200 bg-red-50",
      @is_pending_toggle && "border-amber-200 bg-amber-50",
      !@is_pending_delete && !@is_pending_toggle &&
        "border-[var(--border)] hover:bg-[var(--surface-raised)]"
    ]}>
      <%= if @is_pending_delete do %>
        <td class="px-6 py-3 w-56">
          <div class="text-sm font-medium text-red-800 truncate">{@actor.name}</div>
          <div class="font-mono text-[10px] text-red-400 mt-0.5 truncate">{@actor.id}</div>
        </td>
        <td colspan="6" class="px-6 py-3">
          <div class="flex items-center gap-4">
            <span class="text-xs text-red-700">
              Delete this API Token? This will remove it along with all associated credentials and cannot be undone.
            </span>
            <div class="flex items-center gap-2 ml-auto shrink-0">
              <button
                phx-click="cancel_confirm"
                class="px-2.5 py-1 text-xs rounded border border-red-300 bg-white text-red-800 hover:bg-red-100 transition-colors"
              >
                Cancel
              </button>
              <button
                phx-click="delete"
                phx-value-id={@actor.id}
                class="px-2.5 py-1 text-xs rounded bg-red-600 text-white hover:bg-red-700 transition-colors"
              >
                Delete
              </button>
            </div>
          </div>
        </td>
      <% else %>
        <%= if @is_pending_toggle do %>
          <td class="px-6 py-3 w-56">
            <div class="text-sm font-medium text-amber-800 truncate">{@actor.name}</div>
            <div class="font-mono text-[10px] text-amber-400 mt-0.5 truncate">{@actor.id}</div>
          </td>
          <td colspan="6" class="px-6 py-3">
            <div class="flex items-center gap-4">
              <span class="text-xs text-amber-700">
                {if is_nil(@actor.disabled_at),
                  do: "Disable this API Token? It will no longer be able to authenticate.",
                  else: "Re-enable this API Token?"}
              </span>
              <div class="flex items-center gap-2 ml-auto shrink-0">
                <button
                  phx-click="cancel_confirm"
                  class="px-2.5 py-1 text-xs rounded border border-amber-300 bg-white text-amber-800 hover:bg-amber-100 transition-colors"
                >
                  Cancel
                </button>
                <button
                  phx-click={if is_nil(@actor.disabled_at), do: "disable", else: "enable"}
                  phx-value-id={@actor.id}
                  class="px-2.5 py-1 text-xs rounded bg-amber-600 text-white hover:bg-amber-700 transition-colors"
                >
                  {if is_nil(@actor.disabled_at), do: "Disable", else: "Enable"}
                </button>
              </div>
            </div>
          </td>
        <% else %>
          <td class="px-6 py-3 w-56">
            <div class="text-sm font-medium text-[var(--text-primary)] truncate">{@actor.name}</div>
            <div class="font-mono text-[10px] text-[var(--text-tertiary)] mt-0.5 truncate">
              {@actor.id}
            </div>
          </td>
          <td class="px-6 py-3 w-28">
            <%= if is_nil(@actor.disabled_at) do %>
              <span class="inline-flex items-center text-[10px] font-semibold px-1.5 py-0.5 rounded bg-green-100 text-green-700">
                Active
              </span>
            <% else %>
              <span class="inline-flex items-center text-[10px] font-semibold px-1.5 py-0.5 rounded bg-[var(--surface-raised)] text-[var(--text-tertiary)]">
                Disabled
              </span>
            <% end %>
          </td>
          <td class="px-6 py-3 w-36">
            <span class="text-sm text-[var(--text-secondary)]">
              {PortalWeb.Format.short_date(@actor.inserted_at)}
            </span>
          </td>
          <td class="px-6 py-3 w-36">
            <span class="text-sm text-[var(--text-secondary)]">
              {if @token, do: PortalWeb.Format.short_date(@token.expires_at), else: "—"}
            </span>
          </td>
          <td class="px-6 py-3 w-36">
            <span class="text-sm text-[var(--text-secondary)]">
              <%= if @token && @token.last_seen_at do %>
                <.relative_datetime datetime={@token.last_seen_at} />
              <% else %>
                —
              <% end %>
            </span>
          </td>
          <td class="px-6 py-3 w-36">
            <span class="text-sm text-[var(--text-secondary)]">
              {if @token && @token.last_seen_remote_ip, do: @token.last_seen_remote_ip, else: "—"}
            </span>
          </td>
          <td class="px-6 py-3 w-10">
            <div class="flex justify-end">
              <.popover placement="bottom" trigger="click">
                <:target>
                  <button
                    type="button"
                    class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                  >
                    <.icon name="ri-more-2-line" class="w-4 h-4" />
                  </button>
                </:target>
                <:content>
                  <div class="flex flex-col py-1 w-44">
                    <.link
                      patch={~p"/#{@account}/settings/api_clients/#{@actor}/edit"}
                      class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--text-secondary)]"
                    >
                      <.icon name="ri-pencil-line" class="w-3.5 h-3.5 shrink-0" /> Edit
                    </.link>
                    <div class="my-1 border-t border-[var(--border)]"></div>
                    <button
                      phx-click="request_confirm"
                      phx-value-id={@actor.id}
                      phx-value-action="toggle"
                      class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--text-secondary)]"
                    >
                      <.icon
                        name={
                          if is_nil(@actor.disabled_at),
                            do: "ri-pause-line",
                            else: "ri-play-line"
                        }
                        class="w-3.5 h-3.5 shrink-0"
                      />
                      {if is_nil(@actor.disabled_at), do: "Disable", else: "Enable"}
                    </button>
                    <div class="my-1 border-t border-[var(--border)]"></div>
                    <button
                      phx-click="request_confirm"
                      phx-value-id={@actor.id}
                      phx-value-action="delete"
                      class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-[var(--surface-raised)] transition-colors text-[var(--status-error)]"
                    >
                      <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Delete
                    </button>
                  </div>
                </:content>
              </.popover>
            </div>
          </td>
        <% end %>
      <% end %>
    </tr>
    """
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients")}
  end

  def handle_event("close_reveal", _params, socket) do
    actors_with_tokens = Database.list_actors_with_token(socket.assigns.subject)

    socket =
      socket
      |> assign(actors_with_tokens: actors_with_tokens)
      |> push_patch(to: ~p"/#{socket.assigns.account}/settings/api_clients")

    {:noreply, socket}
  end

  def handle_event(
        "handle_keydown",
        %{"key" => "Escape"},
        %{assigns: %{live_action: action}} = socket
      )
      when action in [:new, :edit] do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/api_clients")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("validate_new", %{"api_token" => attrs}, socket) do
    attrs = map_expires_at(attrs)

    changeset =
      build_creation_changeset(attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset, as: "api_token"))}
  end

  def handle_event("create_token", %{"api_token" => attrs}, socket) do
    account = socket.assigns.account

    if Portal.Billing.can_create_api_clients?(account) do
      attrs = map_expires_at(attrs)
      {name, token_attrs} = Map.pop(attrs, "name")
      actor_changeset = build_actor_changeset(%{"name" => name})

      case Database.create_api_token_with_actor(
             actor_changeset,
             token_attrs,
             socket.assigns.subject
           ) do
        {:ok, {_actor, encoded_token}} ->
          actors_with_tokens = Database.list_actors_with_token(socket.assigns.subject)

          socket =
            socket
            |> assign(encoded_token: encoded_token, actors_with_tokens: actors_with_tokens)

          {:noreply, socket}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset, as: "api_token"))}
      end
    else
      socket =
        socket
        |> put_flash(
          :error,
          "You have reached the maximum number of API tokens allowed for your account."
        )
        |> push_patch(to: ~p"/#{account}/settings/api_clients")

      {:noreply, socket}
    end
  end

  def handle_event("validate_edit", %{"actor" => attrs}, socket) do
    changeset =
      actor_name_changeset(socket.assigns.selected_actor, attrs)
      |> Map.put(:action, :update)

    {:noreply, assign(socket, form: to_form(changeset, as: "actor"))}
  end

  def handle_event("update_actor", %{"actor" => attrs}, socket) do
    changeset = actor_name_changeset(socket.assigns.selected_actor, attrs)

    case Portal.Safe.scoped(changeset, socket.assigns.subject) |> Portal.Safe.update() do
      {:ok, _actor} ->
        actors_with_tokens = Database.list_actors_with_token(socket.assigns.subject)

        socket =
          socket
          |> assign(actors_with_tokens: actors_with_tokens)
          |> push_patch(to: ~p"/#{socket.assigns.account}/settings/api_clients")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "actor"))}
    end
  end

  def handle_event("disable", %{"id" => id}, socket) do
    actor = get_actor_by_id(socket, id)

    changeset =
      actor
      |> change()
      |> put_change(:disabled_at, DateTime.utc_now())

    with {:ok, updated} <-
           Portal.Safe.scoped(changeset, socket.assigns.subject) |> Portal.Safe.update() do
      socket =
        socket
        |> assign(actors_with_tokens: reload_actors_with_tokens(socket), pending_confirm: nil)
        |> maybe_update_selected(updated)

      {:noreply, socket}
    end
  end

  def handle_event("enable", %{"id" => id}, socket) do
    actor = get_actor_by_id(socket, id)

    changeset =
      actor
      |> change()
      |> put_change(:disabled_at, nil)

    with {:ok, updated} <-
           Portal.Safe.scoped(changeset, socket.assigns.subject) |> Portal.Safe.update() do
      socket =
        socket
        |> assign(actors_with_tokens: reload_actors_with_tokens(socket), pending_confirm: nil)
        |> maybe_update_selected(updated)

      {:noreply, socket}
    end
  end

  def handle_event("request_confirm", %{"id" => id, "action" => action}, socket) do
    {:noreply, assign(socket, pending_confirm: %{id: id, action: action})}
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply, assign(socket, pending_confirm: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    actor = get_actor_by_id(socket, id)

    with {:ok, _actor} <-
           Portal.Safe.scoped(actor, socket.assigns.subject) |> Portal.Safe.delete() do
      socket =
        socket
        |> assign(actors_with_tokens: reload_actors_with_tokens(socket), pending_confirm: nil)
        |> push_patch(to: ~p"/#{socket.assigns.account}/settings/api_clients")

      {:noreply, socket}
    end
  end

  defp get_actor_by_id(socket, id) do
    Enum.find_value(socket.assigns.actors_with_tokens, fn {a, _t} -> a.id == id && a end)
  end

  defp reload_actors_with_tokens(socket) do
    Database.list_actors_with_token(socket.assigns.subject)
  end

  defp maybe_update_selected(socket, updated_actor) do
    case socket.assigns.selected_actor do
      %{id: id} when id == updated_actor.id -> assign(socket, selected_actor: updated_actor)
      _ -> socket
    end
  end

  defp build_creation_changeset(attrs) do
    %APIToken{}
    |> cast(attrs, [:name, :expires_at])
    |> validate_required([:name, :expires_at])
  end

  defp build_actor_changeset(attrs) do
    %Actor{type: :api_client}
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end

  defp actor_name_changeset(actor, attrs) do
    actor
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
  end

  defp map_expires_at(attrs) do
    Map.update(attrs, "expires_at", nil, fn
      nil -> nil
      "" -> ""
      value -> "#{value}T00:00:00.000000Z"
    end)
  end
end
