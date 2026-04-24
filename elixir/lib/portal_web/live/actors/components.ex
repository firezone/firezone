defmodule PortalWeb.Actors.Components do
  use PortalWeb, :component_library

  import PortalWeb.Clients.Components, only: [client_os_icon_name: 1]

  attr :account, :any, required: true
  attr :actor, :any, default: nil
  attr :query_params, :map, default: %{}
  attr :subject, :any, required: true
  attr :panel, :map, required: true
  attr :form_state, :map, required: true
  attr :related_state, :map, required: true
  attr :token_state, :map, required: true
  attr :group_membership_state, :map, required: true

  def actor_panel(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.form_state)
      |> assign(assigns.related_state)
      |> assign(assigns.token_state)
      |> assign(assigns.group_membership_state)

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
      <.actor_detail_view
        :if={@actor && @view == :detail}
        account={@account}
        actor={@actor}
        subject={@subject}
        panel={@panel}
        related_state={@related_state}
        token_state={@token_state}
      />

      <.actor_edit_view
        :if={@actor && @view == :edit}
        account={@account}
        actor={@actor}
        panel={@panel}
        form_state={@form_state}
        related_state={@related_state}
        group_membership_state={@group_membership_state}
      />

      <.actor_create_view
        :if={@creating_actor}
        account={@account}
        panel={@panel}
        form_state={@form_state}
        token_state={@token_state}
        group_membership_state={@group_membership_state}
      />
    </div>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :subject, :any, required: true
  attr :panel, :map, required: true
  attr :related_state, :map, required: true
  attr :token_state, :map, required: true

  def actor_detail_view(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.related_state)
      |> assign(assigns.token_state)

    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <.actor_detail_header actor={@actor} groups={@groups} tokens={@tokens} />

      <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
        <div class="flex-1 flex flex-col overflow-hidden">
          <.actor_detail_tabs actor={@actor} active_tab={@active_tab} adding_token={@adding_token} />
          <.actor_detail_content
            account={@account}
            actor={@actor}
            active_tab={@active_tab}
            related_state={@related_state}
            token_state={@token_state}
            panel={@panel}
          />
        </div>

        <.actor_detail_sidebar actor={@actor} subject={@subject} panel={@panel} />
      </div>
    </div>
    """
  end

  attr :actor, :any, required: true
  attr :groups, :list, required: true
  attr :tokens, :list, required: true

  def actor_detail_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
      <div class="flex items-start justify-between gap-3">
        <div class="flex items-center gap-3 min-w-0">
          <.actor_type_icon_circle actor={@actor} />
          <div class="min-w-0">
            <h2 class="text-sm font-semibold text-[var(--text-primary)] truncate">{@actor.name}</h2>
            <p :if={@actor.email} class="text-xs text-[var(--text-tertiary)] truncate">
              {@actor.email}
            </p>
          </div>
        </div>
        <div class="flex items-center gap-1.5 shrink-0">
          <button
            type="button"
            phx-click="open_actor_edit_form"
            class="flex items-center gap-1 px-2.5 py-1.5 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
          >
            <.icon name="ri-pencil-line" class="w-3.5 h-3.5" /> Edit
          </button>
          <button
            phx-click="close_panel"
            class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
            title="Close (Esc)"
          >
            <.icon name="ri-close-line" class="w-4 h-4" />
          </button>
        </div>
      </div>
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
    """
  end

  attr :actor, :any, required: true
  attr :active_tab, :string, required: true
  attr :adding_token, :boolean, required: true

  def actor_detail_tabs(assigns) do
    ~H"""
    <div class="flex shrink-0 border-b border-[var(--border)] bg-[var(--surface-raised)] overflow-x-auto items-center">
      <div class="flex flex-1 px-1 gap-0.5">
        <button
          :if={@actor.type != :service_account}
          type="button"
          phx-click="change_tab"
          phx-value-tab="identities"
          class={[
            "px-3 py-2.5 text-xs font-medium whitespace-nowrap border-b-2 transition-colors",
            if(@active_tab == "identities",
              do: "border-[var(--brand)] text-[var(--brand)]",
              else: "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          <span class="flex items-center gap-1.5">
            <.icon name="ri-id-card-line" class="w-3.5 h-3.5" /> External Identities
          </span>
        </button>
        <button
          :if={@actor.type != :service_account}
          type="button"
          phx-click="change_tab"
          phx-value-tab="client_sessions"
          class={[
            "px-3 py-2.5 text-xs font-medium whitespace-nowrap border-b-2 transition-colors",
            if(@active_tab == "client_sessions",
              do: "border-[var(--brand)] text-[var(--brand)]",
              else: "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          <span class="flex items-center gap-1.5">
            <.icon name="ri-smartphone-line" class="w-3.5 h-3.5" /> Client Sessions
          </span>
        </button>
        <button
          :if={@actor.type != :service_account}
          type="button"
          phx-click="change_tab"
          phx-value-tab="portal_sessions"
          class={[
            "px-3 py-2.5 text-xs font-medium whitespace-nowrap border-b-2 transition-colors",
            if(@active_tab == "portal_sessions",
              do: "border-[var(--brand)] text-[var(--brand)]",
              else: "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          <span class="flex items-center gap-1.5">
            <.icon name="ri-computer-line" class="w-3.5 h-3.5" /> Portal Sessions
          </span>
        </button>
        <button
          :if={@actor.type == :service_account}
          type="button"
          phx-click="change_tab"
          phx-value-tab="tokens"
          class={[
            "px-3 py-2.5 text-xs font-medium whitespace-nowrap border-b-2 transition-colors",
            if(@active_tab == "tokens",
              do: "border-[var(--brand)] text-[var(--brand)]",
              else: "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          <span class="flex items-center gap-1.5">
            <.icon name="ri-key-line" class="w-3.5 h-3.5" /> Tokens
          </span>
        </button>
        <button
          type="button"
          phx-click="change_tab"
          phx-value-tab="groups"
          class={[
            "px-3 py-2.5 text-xs font-medium whitespace-nowrap border-b-2 transition-colors",
            if(@active_tab == "groups",
              do: "border-[var(--brand)] text-[var(--brand)]",
              else: "border-transparent text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
            )
          ]}
        >
          <span class="flex items-center gap-1.5">
            <.icon name="ri-team-line" class="w-3.5 h-3.5" /> Groups
          </span>
        </button>
      </div>
      <div class="shrink-0 px-2">
        <button
          :if={@actor.type == :service_account and @active_tab == "tokens" and not @adding_token}
          type="button"
          phx-click="open_add_token_form"
          class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
        >
          <.icon name="ri-add-line" class="w-3 h-3" /> Add Token
        </button>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :active_tab, :string, required: true
  attr :panel, :map, required: true
  attr :related_state, :map, required: true
  attr :token_state, :map, required: true

  def actor_detail_content(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.related_state)
      |> assign(assigns.token_state)

    ~H"""
    <div class="flex-1 overflow-y-auto">
      <div :if={@actor.type != :service_account and @active_tab == "identities"}>
        <div
          :if={@identities == []}
          class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
        >
          No identity provider accounts linked.
        </div>
        <ul :if={@identities != []}>
          <li :for={identity <- @identities} class="border-b border-[var(--border)] group/item">
            <div
              :if={@confirm_delete_identity_id == identity.id}
              class="flex items-center justify-between gap-2 px-5 py-2.5 bg-[var(--surface-raised)]"
            >
              <span class="text-xs text-[var(--text-secondary)] truncate">
                Delete this identity?
                <span class="block text-[var(--text-tertiary)]">This cannot be undone.</span>
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
                  <.provider_icon type={provider_type_from_issuer(identity.issuer)} class="w-4 h-4" />
                </div>
                <div class="flex-1 min-w-0">
                  <p
                    class="text-sm font-medium text-[var(--text-primary)] truncate"
                    title={identity.issuer}
                  >
                    {identity.issuer}
                  </p>
                  <div class="flex items-center gap-3 mt-0.5">
                    <span :if={identity.email} class="text-xs text-[var(--text-tertiary)] truncate">
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
                    <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5" />
                  </button>
                  <.icon
                    name="ri-arrow-right-s-line"
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

      <div :if={@actor.type != :service_account and @active_tab == "client_sessions"}>
        <div
          :if={@tokens == []}
          class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
        >
          No active client sessions.
        </div>
        <ul :if={@tokens != []}>
          <li :for={token <- @tokens} class="border-b border-[var(--border)] group/item">
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
                      client_os_icon_name(token.latest_session && token.latest_session.user_agent)
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
                <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5" />
              </button>
            </div>
          </li>
        </ul>
      </div>

      <div :if={@actor.type != :service_account and @active_tab == "portal_sessions"}>
        <div
          :if={@sessions == []}
          class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
        >
          No active portal sessions.
        </div>
        <ul :if={@sessions != []}>
          <li :for={session <- @sessions} class="border-b border-[var(--border)] group/item">
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
                    <span>Signed in <.relative_datetime datetime={session.inserted_at} /></span>
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
                <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5" />
              </button>
            </div>
          </li>
        </ul>
      </div>

      <div :if={@actor.type == :service_account and @active_tab == "tokens"}>
        <div :if={@created_token} class="px-5 py-5 space-y-4">
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="text-sm font-semibold text-[var(--text-primary)]">Token Created</p>
              <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                Save this token - you won't be able to see it again.
              </p>
            </div>
            <button
              type="button"
              phx-click="dismiss_created_token"
              class="flex items-center justify-center w-6 h-6 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors shrink-0"
              title="Dismiss"
            >
              <.icon name="ri-close-line" class="w-4 h-4" />
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
              <.icon name="ri-clipboard-line" class="w-4 h-4" />
            </button>
          </div>
        </div>

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

        <div :if={is_nil(@created_token) and not @adding_token}>
          <div
            :if={@tokens == []}
            class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
          >
            No tokens. Add one to authenticate this service account.
          </div>
          <ul :if={@tokens != []}>
            <li :for={token <- @tokens} class="border-b border-[var(--border)] group/item">
              <div
                :if={@confirm_delete_token_id == token.id}
                class="flex items-center justify-between gap-2 px-5 py-2.5 bg-[var(--surface-raised)]"
              >
                <span class="text-xs text-[var(--text-secondary)] truncate">
                  Delete this token?
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
                    <.icon name="ri-key-line" class="w-4 h-4 text-[var(--text-secondary)]" />
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
                  <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5" />
                </button>
              </div>
            </li>
          </ul>
        </div>
      </div>

      <div :if={@active_tab == "groups"}>
        <div
          :if={@groups == []}
          class="flex items-center justify-center h-32 text-sm text-[var(--text-tertiary)]"
        >
          Not a member of any groups.
        </div>
        <ul :if={@groups != []}>
          <li :for={group <- @groups} class="border-b border-[var(--border)] transition-colors">
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
                name="ri-arrow-right-s-line"
                class="w-4 h-4 text-[var(--text-muted)] shrink-0"
              />
            </.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :actor, :any, required: true
  attr :subject, :any, required: true
  attr :panel, :map, required: true

  def actor_detail_sidebar(assigns) do
    assigns = assign(assigns, assigns.panel)

    ~H"""
    <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
      <section>
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
          Details
        </h3>
        <dl class="space-y-3">
          <div>
            <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">Actor ID</dt>
            <dd class="font-mono text-[11px] text-[var(--text-secondary)] break-all">{@actor.id}</dd>
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
                      do: "ri-checkbox-circle-line",
                      else: "ri-prohibited-line"
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
            <.icon name="ri-mail-line" class="w-3.5 h-3.5" /> Send Welcome Email
          </button>
          <div
            :if={
              @actor.type in [:account_user, :account_admin_user] and not is_nil(@actor.email) and
                @welcome_email_sent
            }
            class="flex items-center gap-2 w-full px-3 py-2 rounded text-xs text-green-600 bg-green-50 dark:text-green-400 dark:bg-green-900/20"
          >
            <.icon name="ri-checkbox-circle-line" class="w-3.5 h-3.5" />
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
            <.icon name="ri-pause-line" class="w-3.5 h-3.5" /> Disable
          </button>
          <div
            :if={
              is_nil(@actor.disabled_at) and @actor.id != @subject.actor.id and @confirm_disable_actor
            }
            class="px-3 py-2.5 rounded border border-[var(--border)] bg-[var(--surface-raised)]"
          >
            <p class="text-xs font-medium text-[var(--text-primary)] mb-1">Disable this actor?</p>
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
            <.icon name="ri-play-line" class="w-3.5 h-3.5" /> Enable
          </button>
        </div>
      </section>

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
          <p class="text-xs font-medium text-[var(--status-error)] mb-1">Delete this actor?</p>
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
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :panel, :map, required: true
  attr :form_state, :map, required: true
  attr :related_state, :map, required: true
  attr :group_membership_state, :map, required: true

  def actor_edit_view(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.form_state)
      |> assign(assigns.related_state)
      |> assign(assigns.group_membership_state)

    ~H"""
    <.form
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
                disabled={@is_last_admin}
              />
              <label
                for={"#{@form[:type].id}--user"}
                class={[
                  "flex flex-col gap-1 p-3 rounded-lg border border-[var(--border)] peer-checked:border-[var(--brand)] peer-checked:bg-[var(--surface-raised)] transition-colors",
                  if(@is_last_admin,
                    do: "opacity-50 cursor-not-allowed",
                    else: "cursor-pointer hover:bg-[var(--surface-raised)]"
                  )
                ]}
              >
                <span class="flex items-center gap-1.5 text-xs font-semibold text-[var(--text-primary)]">
                  <.icon name="ri-user-line" class="w-3.5 h-3.5" /> User
                </span>
                <span class="text-[11px] text-[var(--text-tertiary)]">
                  Sign in to Firezone Client apps
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
                  <.icon name="ri-shield-check-line" class="w-3.5 h-3.5" /> Admin
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
        <div :if={@actor.type != :service_account}>
          <div
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
              <input type="hidden" name={@form[:allow_email_otp_sign_in].name} value="false" />
              <.toggle
                id={@form[:allow_email_otp_sign_in].id}
                name={@form[:allow_email_otp_sign_in].name}
                value="true"
                checked={
                  Phoenix.HTML.Form.normalize_value("checkbox", @form[:allow_email_otp_sign_in].value)
                }
              />
            </div>
          </div>
          <p :if={@identities == []} class="mt-1 text-xs text-orange-600">
            This actor has no SSO identity. Disabling Email OTP will lock them out.
          </p>
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
    """
  end

  attr :account, :any, required: true
  attr :panel, :map, required: true
  attr :form_state, :map, required: true
  attr :token_state, :map, required: true
  attr :group_membership_state, :map, required: true

  def actor_create_view(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.form_state)
      |> assign(assigns.token_state)
      |> assign(assigns.group_membership_state)

    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <div class="inline-flex items-center justify-center w-8 h-8 rounded-full bg-neutral-100 dark:bg-neutral-800">
              <.icon name="ri-add-line" class="w-4 h-4 text-neutral-600 dark:text-neutral-300" />
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
            <.icon name="ri-close-line" class="w-4 h-4" />
          </button>
        </div>
      </div>

      <div :if={is_nil(@new_actor_type)} class="flex-1 overflow-y-auto p-5">
        <div class="grid grid-cols-2 gap-3">
          <button
            type="button"
            phx-click="select_new_actor_type"
            phx-value-type="user"
            class="flex flex-col items-center justify-center gap-2 p-5 rounded-lg border-2 border-[var(--border)] hover:border-[var(--brand)] hover:bg-[var(--surface-raised)] transition-all text-center"
          >
            <.icon name="ri-user-line" class="w-8 h-8 text-[var(--text-secondary)]" />
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
            <.icon name="ri-server-line" class="w-8 h-8 text-[var(--text-secondary)]" />
            <span class="text-sm font-semibold text-[var(--text-primary)]">Service Account</span>
            <span class="text-xs text-[var(--text-tertiary)]">
              Used to authenticate headless Clients
            </span>
          </button>
        </div>
      </div>

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
                    <.icon name="ri-user-line" class="w-3.5 h-3.5" /> User
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
                    <.icon name="ri-shield-check-line" class="w-3.5 h-3.5" /> Admin
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
              <input type="hidden" name={@form[:allow_email_otp_sign_in].name} value="false" />
              <.toggle
                id={@form[:allow_email_otp_sign_in].id}
                name={@form[:allow_email_otp_sign_in].name}
                value="true"
                checked={
                  Phoenix.HTML.Form.normalize_value("checkbox", @form[:allow_email_otp_sign_in].value)
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
    """
  end

  attr :pending_additions, :list, default: []
  attr :pending_removals, :list, default: []
  attr :current_groups, :list, default: []
  attr :search_results, :list, default: nil
  attr :account, :any, required: true

  defp actor_group_picker(assigns) do
    ~H"""
    <div>
      <% visible_count =
        length(@current_groups) - length(@pending_removals) + length(@pending_additions) %>
      <h3 class="text-sm font-medium text-[var(--text-secondary)] mb-2">
        Groups ({visible_count})
      </h3>
      <div class="border border-[var(--border)] rounded-md overflow-hidden">
        <div
          class="p-3 bg-[var(--surface-raised)] border-b border-[var(--border)] relative"
          phx-click-away="blur_group_search"
        >
          <div class="relative">
            <.icon
              name="ri-search-line"
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
                <.icon name="ri-user-minus-line" class="w-4 h-4" />
              </button>
              <button
                :if={group.id in @pending_removals}
                type="button"
                phx-click="undo_pending_group_removal"
                phx-value-group_id={group.id}
                class="shrink-0 text-[var(--text-tertiary)] hover:text-[var(--text-primary)] transition-colors"
              >
                <.icon name="ri-arrow-go-back-line" class="w-4 h-4" />
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
                <.icon name="ri-user-minus-line" class="w-4 h-4" />
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

  attr :actor, :any, required: true
  attr :class, :string, default: "w-6 h-6"

  defp actor_type_icon(assigns) do
    ~H"""
    <%= case @actor.type do %>
      <% :service_account -> %>
        <.icon name="ri-server-line" class={@class} />
      <% :account_admin_user -> %>
        <.icon name="ri-shield-check-line" class={@class} />
      <% _ -> %>
        <.icon name="ri-user-line" class={@class} />
    <% end %>
    """
  end

  attr :actor, :any, required: true

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

  attr :actor, :any, required: true

  def actor_type_icon_with_badge(assigns) do
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

  attr :actor, :any, required: true

  defp actor_type_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded-sm text-xs font-medium",
      actor_type_badge_color(@actor.type)
    ]}>
      <.actor_type_icon actor={@actor} class="w-3 h-3" />
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

  @browser_patterns [
    {"iPhone", "os-ios"},
    {"iPad", "os-ios"},
    {"Android", "os-android"},
    {"Macintosh", "os-macos"},
    {"Mac OS X", "os-macos"},
    {"Windows NT", "os-windows"},
    {"linux", "os-linux"}
  ]

  defp session_user_agent_icon(user_agent) when is_binary(user_agent) do
    detect_os_icon(user_agent) || "ri-computer-line"
  end

  defp session_user_agent_icon(_), do: "ri-computer-line"

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
end
