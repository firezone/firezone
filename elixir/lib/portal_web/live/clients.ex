defmodule PortalWeb.Clients do
  use PortalWeb, :live_view
  import PortalWeb.Clients.Components
  alias Portal.{Presence.Clients, ComponentVersions}
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Clients.Account.subscribe(socket.assigns.subject.account.id)
    end

    socket =
      socket
      |> assign(page_title: "Clients")
      |> assign(
        selected_client: nil,
        panel_view: :details,
        client_edit_form: nil,
        confirm_delete_client: false
      )
      |> assign_live_table("clients",
        query_module: Database,
        sortable_fields: [
          {:clients, :name},
          {:latest_session, :version},
          {:latest_session, :inserted_at},
          {:clients, :inserted_at},
          {:latest_session, :user_agent}
        ],
        callback: &handle_clients_update!/2
      )

    {:ok, socket}
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :show}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    client = Database.get_client_for_panel(id, socket.assigns.subject)

    if client do
      {:noreply,
       assign(socket,
         selected_client: client,
         panel_view: :details,
         client_edit_form: nil,
         confirm_delete_client: false
       )}
    else
      {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/clients")}
    end
  end

  def handle_params(%{"id" => id} = params, uri, %{assigns: %{live_action: :edit}} = socket) do
    socket = handle_live_tables_params(socket, params, uri)
    client = Database.get_client_for_panel(id, socket.assigns.subject)

    if client do
      changeset = Database.change_client(client)

      {:noreply,
       assign(socket,
         selected_client: client,
         panel_view: :edit_client,
         client_edit_form: to_form(changeset),
         confirm_delete_client: false
       )}
    else
      {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/clients")}
    end
  end

  def handle_params(params, uri, socket) do
    socket = handle_live_tables_params(socket, params, uri)

    {:noreply,
     assign(socket,
       selected_client: nil,
       panel_view: :details,
       client_edit_form: nil,
       confirm_delete_client: false
     )}
  end

  def handle_clients_update!(socket, list_opts) do
    list_opts = Keyword.put(list_opts, :preload, [:actor, :online?, :last_seen])

    with {:ok, clients, metadata} <- Database.list_clients(socket.assigns.subject, list_opts) do
      {:ok,
       assign(socket,
         clients: clients,
         clients_metadata: metadata
       )}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="relative flex flex-col h-full overflow-hidden">
      <.page_header>
        <:icon>
          <.icon name="remix-mac-line" class="w-16 h-16 text-[var(--brand)]" />
        </:icon>
        <:title>Clients</:title>
        <:description>
          End-user devices and servers that access your protected Resources.
        </:description>
        <:action>
          <.docs_action path="/deploy/clients" />
        </:action>
        <:filters>
          <% verified_count = Enum.count(@clients, &(not is_nil(&1.verified_at))) %>
          <% unverified_count = length(@clients) - verified_count %>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border-emphasis)] bg-[var(--surface-raised)] text-[var(--text-primary)] font-medium">
            All {@clients_metadata.count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            <span class="w-1.5 h-1.5 rounded-full shrink-0 bg-[var(--status-active)]"></span>
            Verified {verified_count}
          </span>
          <span class="flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border border-[var(--border)] text-[var(--text-secondary)]">
            <span class="w-1.5 h-1.5 rounded-full shrink-0 bg-[var(--text-muted)]"></span>
            Unverified {unverified_count}
          </span>
        </:filters>
      </.page_header>

      <div class="flex-1 flex flex-col min-h-0 overflow-hidden">
        <.live_table
          id="clients"
          rows={@clients}
          row_id={&"client-#{&1.id}"}
          row_click={fn client -> ~p"/#{@account}/clients/#{client.id}?#{@query_params}" end}
          row_selected={
            fn client -> not is_nil(@selected_client) and client.id == @selected_client.id end
          }
          filters={@filters_by_table_id["clients"]}
          filter={@filter_form_by_table_id["clients"]}
          ordered_by={@order_by_table_id["clients"]}
          metadata={@clients_metadata}
          class="flex-1 min-h-0"
        >
          <:col :let={client} field={{:clients, :name}} label="Client" class="w-80">
            <div class="flex items-center gap-2">
              <span class="mr-2">
                <.client_os_icon client={client} />
              </span>
              <div>
                <div class="font-medium text-[var(--text-primary)] group-hover:text-[var(--brand)] transition-colors">
                  {client.name}
                </div>
                <div class="font-mono text-[10px] text-[var(--text-tertiary)] mt-0.5">
                  {client.id}
                </div>
              </div>
            </div>
          </:col>
          <:col :let={client} label="Owner">
            <.actor_name_and_role
              account={@account}
              actor={client.actor}
              class="text-sm"
              return_to={@return_to}
            />
          </:col>
          <:col :let={client} field={{:latest_session, :version}} label="Version" class="w-32">
            <.version
              current={client.latest_session && client.latest_session.version}
              latest={ComponentVersions.client_version(client)}
            />
          </:col>
          <:col :let={client} label="Verified" class="w-28">
            <span
              :if={not is_nil(client.verified_at)}
              class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-[var(--status-active)] bg-[var(--status-active-bg)]"
              title="Device attributes of this client are manually verified"
            >
              <.icon name="remix-shield-check-line" class="w-2.5 h-2.5" /> Verified
            </span>
            <span
              :if={is_nil(client.verified_at)}
              class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-[var(--text-muted)] bg-[var(--surface-raised)]"
            >
              Unverified
            </span>
          </:col>
          <:col :let={client} label="Status" class="w-28">
            <.status_badge status={if client.online?, do: :online, else: :offline} />
          </:col>
          <:col
            :let={client}
            field={{:latest_session, :inserted_at}}
            label="Last Started"
            class="hidden lg:table-cell"
          >
            <span class="text-xs text-[var(--text-tertiary)]">
              <.relative_datetime datetime={
                client.latest_session && client.latest_session.inserted_at
              } />
            </span>
          </:col>
          <:col
            :let={client}
            field={{:clients, :inserted_at}}
            label="Created"
            class="hidden lg:table-cell"
          >
            <span class="text-xs text-[var(--text-tertiary)]">
              <.relative_datetime datetime={client.inserted_at} />
            </span>
          </:col>
          <:empty>
            <div class="flex flex-col items-center gap-3 py-16">
              <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
                <svg
                  class="w-4 h-4 text-[var(--text-tertiary)]"
                  viewBox="0 0 16 16"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                  stroke-linecap="round"
                >
                  <rect x="2" y="3" width="12" height="8" rx="1" />
                  <path d="M1 13h14" />
                </svg>
              </div>
              <div class="text-center">
                <p class="text-sm font-medium text-[var(--text-primary)]">No clients yet</p>
                <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                  No clients have connected yet.
                </p>
              </div>
            </div>
          </:empty>
        </.live_table>
      </div>

      <.client_panel
        account={@account}
        client={@selected_client}
        panel_view={@panel_view}
        client_edit_form={@client_edit_form}
        confirm_delete_client={@confirm_delete_client}
        query_params={@query_params}
      />
    </div>
    """
  end

  def handle_event(event, params, socket)
      when event in ["paginate", "order_by", "filter", "table_row_click", "change_limit"],
      do: handle_live_table_event(event, params, socket)

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/clients")}
  end

  def handle_event("open_client_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/clients/#{socket.assigns.selected_client.id}/edit"
     )}
  end

  def handle_event("cancel_client_edit_form", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/clients/#{socket.assigns.selected_client.id}"
     )}
  end

  def handle_event("change_client_edit_form", %{"client" => attrs}, socket) do
    changeset =
      Database.change_client(socket.assigns.selected_client, attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, client_edit_form: to_form(changeset))}
  end

  def handle_event("submit_client_edit_form", %{"client" => attrs}, socket) do
    changeset = Database.change_client(socket.assigns.selected_client, attrs)

    case Database.update_client(changeset, socket.assigns.subject) do
      {:ok, updated_client} ->
        {:noreply,
         socket
         |> put_flash(:success, "Client updated successfully.")
         |> reload_live_table!("clients")
         |> push_patch(to: ~p"/#{socket.assigns.account}/clients/#{updated_client.id}")}

      {:error, changeset} ->
        {:noreply,
         assign(socket, client_edit_form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event("handle_keydown", _params, socket)
      when socket.assigns.panel_view == :edit_client do
    {:noreply,
     push_patch(socket,
       to: ~p"/#{socket.assigns.account}/clients/#{socket.assigns.selected_client.id}"
     )}
  end

  def handle_event("handle_keydown", _params, socket)
      when not is_nil(socket.assigns.selected_client) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/clients")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_delete_client", _params, socket) do
    {:noreply, assign(socket, confirm_delete_client: true)}
  end

  def handle_event("cancel_delete_client", _params, socket) do
    {:noreply, assign(socket, confirm_delete_client: false)}
  end

  def handle_event("delete_client", _params, socket) do
    client = socket.assigns.selected_client

    case Database.delete_client(client, socket.assigns.subject) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:success, "Client \"#{client.name}\" was deleted.")
         |> assign(confirm_delete_client: false)
         |> reload_live_table!("clients")
         |> push_patch(to: ~p"/#{socket.assigns.account}/clients")}

      {:error, _} ->
        {:noreply, assign(socket, confirm_delete_client: false)}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_clients:" <> _account_id} = event,
        socket
      ) do
    rendered_client_ids = Enum.map(socket.assigns.clients, & &1.id)

    if presence_updates_any_id?(event, rendered_client_ids) do
      socket = reload_live_table!(socket, "clients")
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  attr :account, :any, required: true
  attr :client, :any, required: true
  attr :panel_view, :atom, default: :details
  attr :client_edit_form, :any, default: nil
  attr :confirm_delete_client, :boolean, default: false
  attr :query_params, :map, default: %{}

  defp client_panel(assigns) do
    ~H"""
    <div
      id="client-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@client, do: "translate-x-0", else: "translate-x-full")
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <div :if={@client} class="flex flex-col h-full overflow-hidden">
        <%!-- Edit form view --%>
        <div :if={@panel_view == :edit_client} class="flex flex-1 min-h-0 flex-col overflow-hidden">
          <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">Edit Client</h2>
              <button
                phx-click="cancel_client_edit_form"
                class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
                title="Close (Esc)"
              >
                <.icon name="remix-close-line" class="w-4 h-4" />
              </button>
            </div>
          </div>
          <.form
            :if={@client_edit_form}
            for={@client_edit_form}
            phx-submit="submit_client_edit_form"
            phx-change="change_client_edit_form"
            class="flex flex-col flex-1 min-h-0 overflow-hidden"
          >
            <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
              <div>
                <label
                  for={@client_edit_form[:name].id}
                  class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
                >
                  Name <span class="text-[var(--status-error)]">*</span>
                </label>
                <.input
                  field={@client_edit_form[:name]}
                  type="text"
                  placeholder="Client name"
                  phx-debounce="300"
                  required
                />
              </div>
            </div>
            <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-[var(--border)] bg-[var(--surface-overlay)]">
              <button
                type="button"
                phx-click="cancel_client_edit_form"
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
        <%!-- Details view --%>
        <div :if={@panel_view != :edit_client} class="flex flex-col h-full overflow-hidden">
          <%!-- Panel header --%>
          <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="flex items-center gap-2 flex-wrap">
                  <h2 class="text-sm font-semibold text-[var(--text-primary)]">{@client.name}</h2>
                  <span
                    :if={not is_nil(@client.verified_at)}
                    class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-[var(--status-active)] bg-[var(--status-active-bg)]"
                  >
                    <.icon name="remix-shield-check-line" class="w-2.5 h-2.5" /> Verified
                  </span>
                </div>
                <p class="font-mono text-xs text-[var(--text-tertiary)] mt-0.5">{@client.id}</p>
              </div>
              <div class="flex items-center gap-1.5 shrink-0">
                <button
                  phx-click="open_client_edit_form"
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
                  Owner
                </span>
                <span class="text-xs text-[var(--text-secondary)]">{@client.actor.name}</span>
              </div>
              <div class="w-px h-3.5 bg-[var(--border-strong)]"></div>
              <div class="flex items-center gap-1.5">
                <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                  Last Seen
                </span>
                <span class="text-xs text-[var(--text-secondary)]">
                  <.relative_datetime datetime={
                    @client.latest_session && @client.latest_session.inserted_at
                  } />
                </span>
              </div>
              <div class="w-px h-3.5 bg-[var(--border-strong)]"></div>
              <div class="flex items-center gap-1.5">
                <.status_badge status={if @client.online?, do: :online, else: :offline} />
              </div>
            </div>
          </div>
          <%!-- Panel body: two columns --%>
          <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
            <%!-- Left: Owner + Device --%>
            <div class="flex-1 overflow-y-auto">
              <%!-- Owner section --%>
              <div class="px-5 pt-4 pb-3 border-b border-[var(--border)]">
                <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
                  Owner
                </h3>
                <.link
                  navigate={~p"/#{@account}/actors/#{@client.actor.id}"}
                  class="flex items-center gap-3 px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)] hover:border-[var(--border-strong)] transition-colors group"
                >
                  <div class="flex items-center justify-center w-8 h-8 rounded-full shrink-0 text-xs font-semibold bg-[var(--brand-muted)] text-[var(--brand)]">
                    {String.slice(@client.actor.name, 0, 2) |> String.upcase()}
                  </div>
                  <div class="min-w-0">
                    <p class="text-sm font-medium text-[var(--text-primary)] group-hover:text-[var(--brand)] truncate transition-colors">
                      {@client.actor.name}
                    </p>
                    <p :if={@client.actor.email} class="text-xs text-[var(--text-tertiary)] truncate">
                      {@client.actor.email}
                    </p>
                  </div>
                </.link>
              </div>
              <%!-- Device section --%>
              <div class="px-5 pt-4 pb-3 border-b border-[var(--border)]">
                <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
                  Device
                </h3>
                <dl class="space-y-3">
                  <div :if={@client.latest_session}>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Operating System</dt>
                    <dd class="text-sm text-[var(--text-primary)]">
                      <.client_os client={@client} />
                    </dd>
                  </div>
                  <div :if={@client.device_serial}>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Serial Number</dt>
                    <dd class="font-mono text-sm text-[var(--text-primary)] font-medium">
                      {@client.device_serial}
                    </dd>
                  </div>
                  <div :if={@client.device_uuid}>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Device UUID</dt>
                    <dd class="font-mono text-xs text-[var(--text-secondary)] break-all">
                      {@client.device_uuid}
                    </dd>
                  </div>
                  <div :if={@client.identifier_for_vendor}>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">
                      App Installation ID
                    </dt>
                    <dd class="font-mono text-xs text-[var(--text-secondary)] break-all">
                      {@client.identifier_for_vendor}
                    </dd>
                  </div>
                  <div :if={@client.firebase_installation_id}>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">
                      App Installation ID
                    </dt>
                    <dd class="font-mono text-xs text-[var(--text-secondary)] break-all">
                      {@client.firebase_installation_id}
                    </dd>
                  </div>
                </dl>
              </div>
              <%!-- Network section --%>
              <div :if={@client.ipv4_address || @client.ipv6_address} class="px-5 pt-4 pb-3">
                <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
                  Network
                </h3>
                <dl class="space-y-3">
                  <div :if={@client.ipv4_address}>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Tunnel IPv4</dt>
                    <dd class="font-mono text-sm text-[var(--text-primary)]">
                      {@client.ipv4_address.address}
                    </dd>
                  </div>
                  <div :if={@client.ipv6_address}>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Tunnel IPv6</dt>
                    <dd class="font-mono text-xs text-[var(--text-secondary)] break-all">
                      {@client.ipv6_address.address}
                    </dd>
                  </div>
                </dl>
              </div>
            </div>
            <%!-- Right: Details + Danger Zone --%>
            <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
              <section>
                <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
                  Details
                </h3>
                <dl class="space-y-2.5">
                  <div>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Client ID</dt>
                    <dd class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                      {@client.id}
                    </dd>
                  </div>
                  <div :if={@client.external_id}>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">External ID</dt>
                    <dd class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
                      {@client.external_id}
                    </dd>
                  </div>
                  <div>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Verified</dt>
                    <dd>
                      <span
                        :if={not is_nil(@client.verified_at)}
                        class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-[var(--status-active)] bg-[var(--status-active-bg)]"
                      >
                        <.icon name="remix-shield-check-line" class="w-2.5 h-2.5" /> Verified
                      </span>
                      <span
                        :if={is_nil(@client.verified_at)}
                        class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-[var(--text-muted)] bg-[var(--surface-raised)]"
                      >
                        Unverified
                      </span>
                    </dd>
                  </div>
                  <div>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Version</dt>
                    <dd>
                      <.version
                        current={@client.latest_session && @client.latest_session.version}
                        latest={ComponentVersions.client_version(@client)}
                      />
                    </dd>
                  </div>
                  <div>
                    <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Created</dt>
                    <dd class="text-xs text-[var(--text-secondary)]">
                      <.relative_datetime datetime={@client.inserted_at} />
                    </dd>
                  </div>
                </dl>
              </section>
              <div class="border-t border-[var(--border)]"></div>
              <section>
                <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--status-error)]/60 mb-3">
                  Danger Zone
                </h3>
                <button
                  :if={not @confirm_delete_client}
                  type="button"
                  phx-click="confirm_delete_client"
                  class="w-full text-left px-3 py-2 rounded border border-[var(--status-error)]/20 text-xs text-[var(--status-error)] hover:bg-[var(--status-error-bg)] transition-colors"
                >
                  Delete client
                </button>
                <div
                  :if={@confirm_delete_client}
                  class="px-3 py-2.5 rounded border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
                >
                  <p class="text-xs font-medium text-[var(--status-error)] mb-1">
                    Delete this client?
                  </p>
                  <p class="text-xs text-[var(--status-error)]/70 mb-3">
                    This won't prevent the owner from signing in again; to block access, disable the owning actor instead.
                  </p>
                  <div class="flex items-center gap-1.5">
                    <button
                      type="button"
                      phx-click="cancel_delete_client"
                      class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                    >
                      Cancel
                    </button>
                    <button
                      type="button"
                      phx-click="delete_client"
                      class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium"
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </section>
            </div>
          </div>
        </div>
        <%!-- end details view --%>
      </div>
    </div>
    """
  end

  defmodule Database do
    import Ecto.Query
    import Portal.Repo.Query
    alias Portal.{Presence.Clients, ClientSession, Safe}
    alias Portal.Client

    def list_clients(subject, opts \\ []) do
      base_query =
        from(c in Client, as: :clients)
        |> join(
          :left_lateral,
          [clients: c],
          s in subquery(
            from(s in ClientSession,
              where: s.client_id == parent_as(:clients).id,
              where: s.account_id == parent_as(:clients).account_id,
              order_by: [desc: s.inserted_at],
              limit: 1
            )
          ),
          on: true,
          as: :latest_session
        )
        |> select_merge([latest_session: s], %{
          latest_session_inserted_at: s.inserted_at,
          latest_session_version: s.version,
          latest_session_user_agent: s.user_agent
        })

      # Check if we need to prefilter by presence
      base_query =
        case get_in(opts, [:filter, :presence]) do
          "online" ->
            ids = Clients.online_client_ids(subject.account.id)
            where(base_query, [clients: c], c.id in ^ids)

          "offline" ->
            ids = Clients.online_client_ids(subject.account.id)
            where(base_query, [clients: c], c.id not in ^ids)

          _ ->
            base_query
        end

      base_query
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    @spec change_client(Portal.Client.t(), map()) :: Ecto.Changeset.t()
    def change_client(client, attrs \\ %{}) do
      import Ecto.Changeset

      client
      |> cast(attrs, [:name])
      |> validate_required([:external_id, :name])
      |> Portal.Client.changeset()
    end

    @spec update_client(Ecto.Changeset.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Client.t()} | {:error, Ecto.Changeset.t()}
    def update_client(changeset, subject) do
      case Safe.scoped(changeset, subject) |> Safe.update() do
        {:ok, updated_client} ->
          {:ok, Clients.preload_clients_presence([updated_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @spec delete_client(Portal.Client.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Client.t()} | {:error, term()}
    def delete_client(client, subject) do
      case Safe.scoped(client, subject) |> Safe.delete() do
        {:ok, deleted_client} ->
          {:ok, Clients.preload_clients_presence([deleted_client]) |> List.first()}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @spec get_client_for_panel(binary(), Portal.Authentication.Subject.t()) ::
            Portal.Client.t() | nil
    def get_client_for_panel(id, subject) do
      client =
        from(c in Client, as: :clients)
        |> where([clients: c], c.id == ^id)
        |> preload([:actor, :ipv4_address, :ipv6_address])
        |> Safe.scoped(subject, :replica)
        |> Safe.one(fallback_to_primary: true)

      case client do
        %Client{} ->
          session =
            from(s in ClientSession,
              where: s.account_id == ^client.account_id,
              where: s.client_id == ^client.id,
              order_by: [desc: s.inserted_at],
              limit: 1
            )
            |> Safe.unscoped(:replica)
            |> Safe.one(fallback_to_primary: true)

          client = Clients.preload_clients_presence([client]) |> List.first()
          %{client | latest_session: session}

        _ ->
          nil
      end
    end

    def cursor_fields do
      [
        {:latest_session, :desc, :inserted_at},
        {:clients, :asc, :id}
      ]
    end

    def preloads do
      [
        :actor,
        online?: &Clients.preload_clients_presence/1,
        last_seen: &preload_latest_sessions/1
      ]
    end

    # The latest session fields are already loaded by the lateral join in list_clients/2.
    # We build the struct from those virtual fields to avoid a redundant DB round-trip.
    defp preload_latest_sessions(clients) do
      Enum.map(clients, fn client ->
        if client.latest_session_inserted_at do
          %{
            client
            | latest_session: %ClientSession{
                version: client.latest_session_version,
                inserted_at: client.latest_session_inserted_at,
                user_agent: client.latest_session_user_agent
              }
          }
        else
          client
        end
      end)
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :name,
          title: "Client or Actor",
          type: {:string, :websearch},
          fun: &filter_by_name_or_email_fts/2
        },
        %Portal.Repo.Filter{
          name: :verification,
          title: "Verification Status",
          type: :string,
          values: [
            {"Verified", "verified"},
            {"Not Verified", "not_verified"}
          ],
          fun: &filter_by_verification/2
        },
        %Portal.Repo.Filter{
          name: :presence,
          title: "Presence",
          type: :string,
          values: [
            {"Online", "online"},
            {"Offline", "offline"}
          ],
          fun: &filter_by_presence/2
        }
      ]
    end

    def filter_by_name_or_email_fts(queryable, name_or_email) do
      queryable =
        if has_named_binding?(queryable, :actors) do
          queryable
        else
          join(queryable, :inner, [clients: c], a in assoc(c, :actor), as: :actors)
        end

      {queryable,
       dynamic(
         [clients: clients, actors: actors],
         fulltext_search(clients.name, ^name_or_email) or
           fulltext_search(actors.name, ^name_or_email) or
           fulltext_search(actors.email, ^name_or_email)
       )}
    end

    def filter_by_verification(queryable, "verified") do
      {queryable, dynamic([clients: clients], not is_nil(clients.verified_at))}
    end

    def filter_by_verification(queryable, "not_verified") do
      {queryable, dynamic([clients: clients], is_nil(clients.verified_at))}
    end

    def filter_by_presence(queryable, _presence) do
      # This is handled as a prefilter in list_clients
      # Return the queryable unchanged since actual filtering happens above
      {queryable, true}
    end
  end
end
