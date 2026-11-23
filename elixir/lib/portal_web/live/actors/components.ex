defmodule PortalWeb.Actors.Components do
  use PortalWeb, :component_library

  alias PortalWeb.Devices

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
    <Page.detail_modal
      id="actor-panel"
      open={not is_nil(@actor) or @creating_actor}
      on_close="handle_keydown"
      size="xl"
    >
      <.actor_detail_view
        :if={@actor && @view == :detail}
        account={@account}
        actor={@actor}
        subject={@subject}
        panel={@panel}
        related_state={@related_state}
        token_state={@token_state}
        group_membership_state={@group_membership_state}
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
    </Page.detail_modal>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :subject, :any, required: true
  attr :panel, :map, required: true
  attr :related_state, :map, required: true
  attr :token_state, :map, required: true
  attr :group_membership_state, :map, required: true

  defp actor_detail_view(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.related_state)
      |> assign(assigns.token_state)
      |> assign(assigns.group_membership_state)

    assigns =
      assigns
      |> assign(:disabling_directory_name, disabling_directory_name(assigns.actor, assigns.identities))
      |> assign(:tab, normalize_tab(assigns.actor, assigns.active_tab))

    ~H"""
    <div class="flex flex-col min-h-0 h-full">
      <.actor_detail_header
        account={@account}
        actor={@actor}
        subject={@subject}
        tokens={@tokens}
        confirm_disable_actor={@confirm_disable_actor}
        confirm_delete_actor={@confirm_delete_actor}
        disabling_directory_name={@disabling_directory_name}
      />

      <div class="flex-1 overflow-y-auto">
        <div class="grid gap-8 px-6 py-6 md:grid-cols-3">
          <.actor_groups_section
            account={@account}
            groups={@groups}
            search_results={@group_search_results}
          />
          <.actor_devices_section account={@account} devices={@devices} />
          <.actor_reach_section account={@account} reach={@reach} />
        </div>

        <div class="border-t border-hair">
          <.actor_detail_tabs actor={@actor} tab={@tab} adding_token={@adding_token} />
          <.actor_detail_content
            account={@account}
            actor={@actor}
            tab={@tab}
            related_state={@related_state}
            token_state={@token_state}
            panel={@panel}
          />
        </div>

        <.actor_details_section
          actor={@actor}
          subject={@subject}
          welcome_email_sent={@welcome_email_sent}
          disabling_directory_name={@disabling_directory_name}
        />
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :subject, :any, required: true
  attr :tokens, :list, required: true
  attr :confirm_disable_actor, :boolean, required: true
  attr :confirm_delete_actor, :boolean, required: true
  attr :disabling_directory_name, :string, default: nil

  defp actor_detail_header(assigns) do
    assigns = assign(assigns, :self?, assigns.actor.id == assigns.subject.actor.id)

    ~H"""
    <div class="shrink-0 px-6 pt-5 pb-4 border-b border-hair">
      <div class="flex items-start gap-4">
        <.actor_avatar account={@account} actor={@actor} size="lg" />
        <div class="min-w-0 flex-1">
          <h2 class="flex items-center gap-2 text-[22px] leading-tight font-bold tracking-tight text-fg">
            <span class="truncate">{@actor.name}</span>
            <Core.badge :if={@actor.type == :account_admin_user} size="xs">Admin</Core.badge>
            <.actor_status_badge
              :if={@actor.is_disabled}
              is_disabled
              disabled_by_directory={not is_nil(@actor.disabled_by_directory_id)}
            />
          </h2>
          <p class="mt-1 text-sm text-muted truncate">
            <%= if @actor.type == :service_account do %>
              <.token_expiry tokens={@tokens} />
            <% else %>
              {@actor.email || "No email"}
            <% end %>
          </p>
        </div>
        <div class="flex flex-wrap items-center justify-end gap-1.5 shrink-0">
          <Form.button
            navigate={~p"/#{@account}/activity?#{[pivot: ["actor:#{@actor.id}"]]}"}
            size="sm"
            icon="ri-pulse-line"
          >
            Activity
          </Form.button>
          <Form.button type="button" phx-click={Page.instant("Edit " <> @actor.name, size: "xl") |> JS.push("open_actor_edit_form")} size="sm" icon="ri-pencil-line">
            Edit
          </Form.button>
          <Form.button
            :if={not @actor.is_disabled and not @self? and not @confirm_disable_actor}
            type="button"
            phx-click="confirm_disable_actor"
            size="sm"
            icon="ri-pause-circle-line"
          >
            Disable
          </Form.button>
          <Form.button
            :if={@actor.is_disabled}
            type="button"
            phx-click="enable"
            phx-value-id={@actor.id}
            size="sm"
            icon="ri-play-circle-line"
          >
            Enable
          </Form.button>
          <Form.button
            :if={not @self? and not @confirm_delete_actor}
            type="button"
            phx-click="confirm_delete_actor"
            style="danger"
            size="sm"
            icon="ri-delete-bin-line"
          >
            Delete
          </Form.button>
          <Form.icon_button
            icon="ri-close-line"
            title="Close (Esc)"
            phx-click={Page.close_modal({:closest, "[data-modal-layer]"}, "close_panel")}
          />
        </div>
      </div>

      <div
        :if={@actor.is_disabled and @actor.disabled_by_directory_id}
        class="flex gap-2 mt-4 px-3 py-2 text-xs text-attn bg-attn-wash"
        data-testid="directory-disabled-notice"
      >
        <Core.icon name="ri-information-line" class="w-3.5 h-3.5 shrink-0 mt-px" />
        <span>
          {@disabling_directory_name} disabled this actor because its user is suspended or
          deactivated there. If you enable it while the user is still inactive, the next
          sync disables it again.
        </span>
      </div>

      <div
        :if={not @actor.is_disabled and not @self? and @confirm_disable_actor}
        class="mt-4 px-4 py-3 border border-rule"
      >
        <p class="text-sm font-semibold text-fg">Disable this actor?</p>
        <p class="mt-1 text-xs text-muted">
          Disabling this actor will immediately disconnect all its Clients.
        </p>
        <p class="flex gap-1.5 mt-1 text-xs text-attn">
          <Core.icon name="ri-error-warning-line" class="w-3.5 h-3.5 shrink-0 mt-px" />
          <span>
            Its sessions and tokens are paused, not revoked. They work again if you re-enable the actor.
          </span>
        </p>
        <div class="flex items-center gap-1.5 mt-3">
          <Form.button type="button" phx-click="cancel_disable_actor" size="xs">Cancel</Form.button>
          <Form.button type="button" phx-click="disable" phx-value-id={@actor.id} size="xs">
            Disable
          </Form.button>
        </div>
      </div>

      <div
        :if={not @self? and @confirm_delete_actor}
        class="mt-4 px-4 py-3 border border-attn bg-attn-wash"
      >
        <p class="text-sm font-semibold text-attn">Delete this actor?</p>
        <p class="mt-1 text-xs text-attn">
          All active sessions will be immediately revoked and this cannot be undone.
        </p>
        <div class="flex items-center gap-1.5 mt-3">
          <Form.button type="button" phx-click="cancel_delete_actor" size="xs">Cancel</Form.button>
          <Form.button
            type="button"
            phx-click="delete"
            phx-value-id={@actor.id}
            style="danger"
            size="xs"
          >
            Delete
          </Form.button>
        </div>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :groups, :list, required: true
  attr :search_results, :any, default: nil

  defp actor_groups_section(assigns) do
    ~H"""
    <section id="actor-groups" class="min-w-0">
      <.eyebrow icon="ri-team-line">Groups</.eyebrow>
      <ul class="border-t border-rule">
        <li
          :for={row <- @groups}
          id={"actor-group-#{row.group.id}"}
          class="flex items-center justify-between gap-3 py-2 border-b border-hair"
        >
          <div class="flex items-center gap-2 min-w-0">
            <Core.provider_icon provider={Core.provider_type_from_group(row)} size="xs" />
            <.link
              navigate={~p"/#{@account}/groups/#{row.group.id}"}
              class="text-sm text-fg truncate hover:underline"
            >
              {row.group.name}
            </.link>
          </div>
          <button
            :if={manual_group?(row.group)}
            type="button"
            phx-click="remove_actor_from_group"
            phx-value-group_id={row.group.id}
            class="shrink-0 text-xs text-muted hover:text-attn"
            title={"Remove from #{row.group.name}"}
          >
            remove
          </button>
          <span :if={not manual_group?(row.group)} class="shrink-0 text-xs text-faint">
            {if row.group.type == :managed, do: "built in", else: "synced"}
          </span>
        </li>
      </ul>
      <p :if={@groups == []} class="flex items-center gap-2 py-3 text-sm text-muted">
        <Core.icon name="ri-team-line" class="w-4 h-4 text-faint" /> Not in any group.
      </p>
      <div class="relative mt-3" phx-click-away="blur_group_search">
        <Core.icon
          name="ri-add-line"
          class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-muted pointer-events-none"
        />
        <input
          id="actor-add-group-search"
          type="text"
          name="value"
          placeholder="Add to a group..."
          phx-change="search_actor_groups"
          phx-focus="focus_group_search"
          phx-debounce="300"
          autocomplete="off"
          data-1p-ignore
          class="w-full pl-8 pr-3 py-1.5 text-sm border border-rule bg-bg text-fg placeholder:text-muted outline-none focus:border-fg"
        />
        <div
          :if={@search_results != nil}
          class="absolute z-10 left-0 right-0 mt-1 bg-bg border border-rule shadow-lg max-h-56 overflow-y-auto"
        >
          <button
            :for={group <- @search_results}
            type="button"
            phx-click="add_actor_to_group"
            phx-value-group_id={group.id}
            class="flex items-center gap-2 w-full text-left px-3 py-2 text-sm text-fg border-b border-hair last:border-b-0 hover:bg-hover"
          >
            <Core.icon name="ri-team-line" class="w-3.5 h-3.5 text-muted" />
            <span class="truncate">{group.name}</span>
          </button>
          <p :if={@search_results == []} class="px-3 py-3 text-xs text-muted">
            Type a group name to search.
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :account, :any, required: true
  attr :devices, :list, required: true

  defp actor_devices_section(assigns) do
    ~H"""
    <section id="actor-devices" class="min-w-0">
      <.eyebrow icon="ri-macbook-line">Devices</.eyebrow>
      <ul class="border-t border-rule">
        <li
          :for={device <- @devices}
          id={"actor-device-#{device.id}"}
          class="flex items-center justify-between gap-3 py-2 border-b border-hair"
        >
          <div class="flex items-center gap-2 min-w-0">
            <.presence_dot online={device.online?} />
            <.link
              navigate={~p"/#{@account}/devices/#{device.id}"}
              class="text-sm text-fg truncate hover:underline"
            >
              {device.name || "Unnamed device"}
            </.link>
          </div>
          <span class="shrink-0 text-xs text-muted">
            <%= if device.online? do %>
              online
            <% else %>
              <Core.relative_datetime datetime={device.last_seen_at} popover={false} />
            <% end %>
          </span>
        </li>
      </ul>
      <p :if={@devices == []} class="flex items-center gap-2 py-3 text-sm text-muted">
        <Core.icon name="ri-macbook-line" class="w-4 h-4 text-faint" /> No devices yet.
      </p>
    </section>
    """
  end

  attr :account, :any, required: true
  attr :reach, :list, required: true

  defp actor_reach_section(assigns) do
    ~H"""
    <section id="actor-reach" class="min-w-0">
      <.eyebrow icon="ri-route-line">Can reach</.eyebrow>
      <ul class="border-t border-rule">
        <li
          :for={row <- @reach}
          class="flex items-start justify-between gap-3 py-2 border-b border-hair"
        >
          <div class="min-w-0">
            <.link
              navigate={~p"/#{@account}/resources/#{row.resource.id}"}
              class="block text-sm text-fg truncate hover:underline"
            >
              {row.resource.name}
            </.link>
            <p class="text-xs text-muted truncate">
              <%= if PortalWeb.DirectAccess.direct_group?(row.group) do %>
                direct access
              <% else %>
                through
                <.link navigate={~p"/#{@account}/groups/#{row.group.id}"} class="hover:underline">
                  {row.group.name}
                </.link>
              <% end %>
            </p>
          </div>
          <.route_chip resource={row.resource} site_name={row.site_name} />
        </li>
      </ul>
      <p :if={@reach == []} class="flex items-center gap-2 py-3 text-sm text-muted">
        <Core.icon name="ri-route-line" class="w-4 h-4 text-faint" /> Nothing yet.
      </p>
    </section>
    """
  end

  @doc """
  How traffic reaches a resource: through a site, or directly for a device pool.
  """
  attr :resource, :any, required: true
  attr :site_name, :string, default: nil

  def route_chip(assigns) do
    ~H"""
    <Core.badge :if={@resource.type == :device_pool} class="shrink-0 border-dashed">
      direct
    </Core.badge>
    <Core.badge :if={@resource.type != :device_pool and @site_name} class="shrink-0">
      via {@site_name}
    </Core.badge>
    <Core.badge :if={@resource.type != :device_pool and is_nil(@site_name)} class="shrink-0">
      {ResourceType.resource_type_label(@resource.type)}
    </Core.badge>
    """
  end

  attr :actor, :any, required: true
  attr :tab, :string, required: true
  attr :adding_token, :boolean, required: true

  defp actor_detail_tabs(assigns) do
    ~H"""
    <div class="flex items-center gap-1 px-6 border-b border-hair overflow-x-auto">
      <.tab_button
        :if={@actor.type != :service_account}
        tab="identities"
        active={@tab}
        icon="ri-id-card-line"
      >
        Identities
      </.tab_button>
      <.tab_button
        :if={@actor.type != :service_account}
        tab="client_sessions"
        active={@tab}
        icon="ri-smartphone-line"
      >
        Client sessions
      </.tab_button>
      <.tab_button
        :if={@actor.type != :service_account}
        tab="portal_sessions"
        active={@tab}
        icon="ri-computer-line"
      >
        Portal sessions
      </.tab_button>
      <.tab_button :if={@actor.type == :service_account} tab="tokens" active={@tab} icon="ri-key-line">
        Tokens
      </.tab_button>
      <div class="ml-auto shrink-0">
        <Form.button
          :if={@actor.type == :service_account and @tab == "tokens" and not @adding_token}
          type="button"
          phx-click="open_add_token_form"
          size="xs"
          icon="ri-add-line"
        >
          Add token
        </Form.button>
      </div>
    </div>
    """
  end

  attr :tab, :string, required: true
  attr :active, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp tab_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="change_tab"
      phx-value-tab={@tab}
      class={[
        "flex items-center gap-1.5 px-2 py-2.5 -mb-px text-xs font-medium whitespace-nowrap border-b-2",
        if(@active == @tab,
          do: "border-fg text-fg",
          else: "border-transparent text-muted hover:text-fg"
        )
      ]}
    >
      <Core.icon name={@icon} class="w-3.5 h-3.5" /> {render_slot(@inner_block)}
    </button>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :tab, :string, required: true
  attr :panel, :map, required: true
  attr :related_state, :map, required: true
  attr :token_state, :map, required: true

  defp actor_detail_content(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.related_state)
      |> assign(assigns.token_state)
      |> assign(:api_url, PortalWeb.DeploymentURLs.api_url())

    ~H"""
    <div>
      <div :if={@tab == "identities"}>
        <.empty_tab :if={@identities == []} icon="ri-id-card-line">
          No identity provider accounts linked.
        </.empty_tab>
        <ul :if={@identities != []}>
          <li :for={identity <- @identities} class="border-b border-hair">
            <.confirm_row
              :if={@confirm_delete_identity_id == identity.id}
              question="Delete this identity?"
              cancel="cancel_delete_identity"
              confirm="delete_identity"
              id={identity.id}
              label="Delete"
            />
            <details :if={@confirm_delete_identity_id != identity.id} class="group/details">
              <summary class="flex items-center gap-4 px-6 py-3 cursor-pointer list-none hover:bg-hover">
                <.avatar account={@account} identity_id={identity.id} etag={identity.avatar_etag} />
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-1.5">
                    <p class="text-sm font-medium text-fg truncate">
                      {identity_display_name(identity)}
                    </p>
                    <Core.provider_icon provider={Core.provider_type_from_issuer(identity.issuer)} size="xs" />
                  </div>
                  <p :if={identity.email} class="text-xs text-muted truncate mt-0.5">
                    {identity.email}
                  </p>
                </div>
                <.row_actions confirm="confirm_delete_identity" id={identity.id} title="Delete identity" />
              </summary>
              <.detail_grid>
                <.detail_field label="Issuer" mono title={identity.issuer} class="col-span-2">
                  {identity.issuer}
                </.detail_field>
                <.detail_field :if={identity.directory_name} label="Directory" title={identity.directory_name}>
                  {identity.directory_name}
                </.detail_field>
                <.detail_field label="IDP ID" mono title={identity.idp_id}>
                  {extract_idp_id(identity.idp_id)}
                </.detail_field>
                <.detail_field :if={identity.email} label="Email">{identity.email}</.detail_field>
                <.detail_field :if={identity.name} label="Name">{identity.name}</.detail_field>
                <.detail_field :if={identity.given_name} label="Given name">
                  {identity.given_name}
                </.detail_field>
                <.detail_field :if={identity.family_name} label="Family name">
                  {identity.family_name}
                </.detail_field>
                <.detail_field :if={identity.middle_name} label="Middle name">
                  {identity.middle_name}
                </.detail_field>
                <.detail_field :if={identity.nickname} label="Nickname">{identity.nickname}</.detail_field>
                <.detail_field :if={identity.preferred_username} label="Preferred username">
                  {identity.preferred_username}
                </.detail_field>
                <.detail_field
                  :if={Ecto.assoc_loaded?(identity.sync_state) && identity.sync_state && identity.sync_state.synced_at}
                  label="Last synced"
                >
                  <Core.relative_datetime datetime={identity.sync_state.synced_at} />
                </.detail_field>
              </.detail_grid>
            </details>
          </li>
        </ul>
      </div>

      <div :if={@tab == "client_sessions"}>
        <.empty_tab :if={@tokens == []} icon="ri-smartphone-line">No active client sessions.</.empty_tab>
        <ul :if={@tokens != []}>
          <li :for={token <- @tokens} class="border-b border-hair">
            <.confirm_row
              :if={@confirm_delete_token_id == token.id}
              question="Revoke this session?"
              cancel="cancel_delete_token"
              confirm="delete_token"
              id={token.id}
              label="Revoke"
            />
            <details :if={@confirm_delete_token_id != token.id} class="group/details">
              <summary class="flex items-center gap-3 px-6 py-3 cursor-pointer list-none hover:bg-hover">
                <.presence_dot online={token.online?} />
                <Core.icon
                  name={Devices.Components.os_icon_name(token.last_used_device && token.last_used_device.last_seen_user_agent)}
                  class="w-4 h-4 text-muted shrink-0"
                />
                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium text-fg">
                    {if token.online?, do: "Online", else: "Offline"}
                  </p>
                  <div class="flex items-center gap-3 mt-0.5 text-xs text-muted">
                    <span>
                      Connected
                      <Core.relative_datetime datetime={token.last_used_device && token.last_used_device.last_seen_at} />
                    </span>
                    <span :if={token_place(token)}>Location: {token_place(token)}</span>
                  </div>
                </div>
                <.row_actions confirm="confirm_delete_token" id={token.id} title="Revoke session" />
              </summary>
              <.session_details device={token.last_used_device} location={token_location(token)}>
                <.detail_field label="Token ID" mono>{token.id}</.detail_field>
                <.detail_field :if={token.expires_at} label="Token expires">
                  <Core.relative_datetime datetime={token.expires_at} />
                </.detail_field>
              </.session_details>
            </details>
          </li>
        </ul>
      </div>

      <div :if={@tab == "portal_sessions"}>
        <.empty_tab :if={@sessions == []} icon="ri-computer-line">No active portal sessions.</.empty_tab>
        <ul :if={@sessions != []}>
          <li :for={session <- @sessions} class="border-b border-hair">
            <.confirm_row
              :if={@confirm_delete_session_id == session.id}
              question="Revoke this session?"
              cancel="cancel_delete_session"
              confirm="delete_session"
              id={session.id}
              label="Revoke"
            />
            <details :if={@confirm_delete_session_id != session.id} class="group/details">
              <summary class="flex items-center gap-3 px-6 py-3 cursor-pointer list-none hover:bg-hover">
                <.presence_dot online={session.online?} />
                <Core.icon name={session_user_agent_icon(session.user_agent)} class="w-4 h-4 text-muted shrink-0" />
                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium text-fg">
                    {if session.online?, do: "Online", else: "Offline"}
                  </p>
                  <div class="flex items-center gap-3 mt-0.5 text-xs text-muted">
                    <span>Signed in <Core.relative_datetime datetime={session.inserted_at} /></span>
                    <span :if={session_location(session) || session.remote_ip}>
                      Location: {session_location(session) || session.remote_ip}
                    </span>
                  </div>
                </div>
                <.row_actions confirm="confirm_delete_session" id={session.id} title="Revoke session" />
              </summary>
              <.detail_grid>
                <.detail_field :if={session.remote_ip} label="IP Address" mono>
                  {session.remote_ip}
                </.detail_field>
                <.detail_field :if={session_location(session)} label="Location">
                  {session_location(session)}
                </.detail_field>
                <.detail_field :if={session.user_agent} label="User Agent" title={session.user_agent}>
                  {session.user_agent}
                </.detail_field>
                <.detail_field :if={session.auth_provider_name} label="Auth provider">
                  {session.auth_provider_name}
                </.detail_field>
                <.detail_field label="Signed in">
                  <Core.relative_datetime datetime={session.inserted_at} />
                </.detail_field>
                <.detail_field :if={session.expires_at} label="Expires">
                  <Core.relative_datetime datetime={session.expires_at} />
                </.detail_field>
                <.detail_field label="Session ID" mono>{session.id}</.detail_field>
              </.detail_grid>
            </details>
          </li>
        </ul>
      </div>

      <div :if={@tab == "tokens"}>
        <div :if={@created_token} class="px-6 py-5 space-y-4">
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="text-sm font-semibold text-fg">Token Created</p>
              <p class="text-xs text-muted mt-0.5">
                Save this token - you won't be able to see it again.
              </p>
            </div>
            <Form.icon_button icon="ri-close-line" title="Dismiss" phx-click="dismiss_created_token" size="sm" />
          </div>
          <div id="tab-token-copy" class="relative" phx-hook="CopyClipboard">
            <code
              id="tab-token-copy-code"
              class="block font-mono text-[11px] break-all bg-hover border border-hair px-3 py-2.5 pr-9 text-fg"
            >
              {@created_token}
            </code>
            <button
              type="button"
              data-copy-to-clipboard-target="tab-token-copy-code"
              data-copy-to-clipboard-content-type="innerHTML"
              data-copy-to-clipboard-html-entities="true"
              class="absolute top-2 right-2 text-muted hover:text-fg"
              title="Copy token"
            >
              <Core.icon name="ri-clipboard-line" class="w-4 h-4" />
            </button>
          </div>
          <p :if={@api_url} id="tab-token-api-url" class="text-xs text-muted">
            Set <code class="font-mono">FIREZONE_API_URL={@api_url}</code>
            alongside <code class="font-mono">FIREZONE_TOKEN</code>
            so the headless Client connects to this portal.
          </p>
        </div>

        <div :if={is_nil(@created_token) and @adding_token} class="px-6 py-4 space-y-4">
          <p class="text-sm font-medium text-fg">New Token</p>
          <form id="create-token-form" phx-change="validate_token" phx-submit="create_token" class="space-y-4">
            <div>
              <label class="block text-xs font-medium text-muted mb-1.5">Token expiration</label>
              <input
                type="date"
                name="token_expiration"
                value={@token_expiration}
                class="block w-full border-rule bg-bg text-fg focus:border-fg focus:ring-0 text-sm"
                required
              />
            </div>
            <div class="flex items-center gap-2">
              <Form.button type="button" phx-click="cancel_add_token_form" size="xs">Cancel</Form.button>
              <Form.button type="submit" style="primary" size="xs">Create Token</Form.button>
            </div>
          </form>
        </div>

        <div :if={is_nil(@created_token) and not @adding_token}>
          <.empty_tab :if={@tokens == []} icon="ri-key-line">
            No tokens. Add one to authenticate this service account.
          </.empty_tab>
          <ul :if={@tokens != []}>
            <li :for={token <- @tokens} class="border-b border-hair">
              <.confirm_row
                :if={@confirm_delete_token_id == token.id}
                question="Delete this token?"
                cancel="cancel_delete_token"
                confirm="delete_token"
                id={token.id}
                label="Delete"
              />
              <details :if={@confirm_delete_token_id != token.id} class="group/details">
                <summary class="flex items-center gap-3 px-6 py-3 cursor-pointer list-none hover:bg-hover">
                  <.presence_dot online={token.online?} />
                  <Core.icon name="ri-key-line" class="w-4 h-4 text-muted shrink-0" />
                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-medium text-fg">
                      {if token.online?, do: "Active", else: "Inactive"}
                    </p>
                    <div class="flex items-center gap-3 mt-0.5 text-xs text-muted">
                      <span>
                        Last used:
                        <Core.relative_datetime datetime={token.last_used_device && token.last_used_device.last_seen_at} />
                      </span>
                      <span :if={token.expires_at}>
                        Expires: <Core.relative_datetime datetime={token.expires_at} />
                      </span>
                      <span :if={token_place(token)}>Location: {token_place(token)}</span>
                    </div>
                  </div>
                  <.row_actions confirm="confirm_delete_token" id={token.id} title="Delete token" />
                </summary>
                <.session_details device={token.last_used_device} location={token_location(token)}>
                  <.detail_field label="Token ID" mono>{token.id}</.detail_field>
                  <.detail_field :if={token.expires_at} label="Token expires">
                    <Core.relative_datetime datetime={token.expires_at} />
                  </.detail_field>
                  <.detail_field label="Created">
                    <Core.relative_datetime datetime={token.inserted_at} />
                  </.detail_field>
                </.session_details>
              </details>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :actor, :any, required: true
  attr :subject, :any, required: true
  attr :welcome_email_sent, :boolean, required: true
  attr :disabling_directory_name, :string, default: nil

  defp actor_details_section(assigns) do
    assigns =
      assign(
        assigns,
        :welcome_email?,
        assigns.actor.type in [:account_user, :account_admin_user] and not is_nil(assigns.actor.email)
      )

    ~H"""
    <details id="actor-details" class="group/more border-t border-hair">
      <summary class="flex items-center gap-2 px-6 py-3 cursor-pointer list-none hover:bg-hover">
        <Core.icon name="ri-information-line" class="w-4 h-4 text-muted" />
        <span class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">Details</span>
        <Core.icon name="ri-arrow-down-s-line" class="w-4 h-4 text-muted group-open/more:hidden" />
        <Core.icon name="ri-arrow-up-s-line" class="w-4 h-4 text-muted hidden group-open/more:block" />
      </summary>
      <div class="px-6 pb-6">
        <dl class="grid gap-x-8 gap-y-3 sm:grid-cols-2 lg:grid-cols-3">
          <.detail_field label="Actor ID" mono>{@actor.id}</.detail_field>
          <.detail_field :if={@actor.email} label="Email">{@actor.email}</.detail_field>
          <.detail_field label="Role">{actor_display_type(@actor)}</.detail_field>
          <.detail_field label="Created">
            <Core.relative_datetime datetime={@actor.inserted_at} />
          </.detail_field>
          <.detail_field label="Updated">
            <Core.relative_datetime datetime={@actor.updated_at} />
          </.detail_field>
          <.detail_field :if={@actor.type != :service_account} label="Email OTP sign in">
            {if @actor.allow_email_otp_sign_in, do: "Allowed", else: "Not Allowed"}
          </.detail_field>
          <div :if={@actor.disabled_by_directory_id}>
            <dt class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">Disabled by</dt>
            <dd class="text-sm text-fg mt-0.5" data-testid="disabled-by-directory">
              {@disabling_directory_name}
            </dd>
          </div>
        </dl>
        <div :if={@welcome_email?} class="mt-4">
          <Form.button
            :if={not @welcome_email_sent}
            type="button"
            phx-click="send_welcome_email"
            phx-value-id={@actor.id}
            size="sm"
            icon="ri-mail-line"
          >
            Send welcome email
          </Form.button>
          <p :if={@welcome_email_sent} class="flex items-center gap-2 text-xs text-fg">
            <Core.icon name="ri-checkbox-circle-line" class="w-3.5 h-3.5" />
            Email sent to {@actor.email}
          </p>
        </div>
      </div>
    </details>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :panel, :map, required: true
  attr :form_state, :map, required: true
  attr :related_state, :map, required: true
  attr :group_membership_state, :map, required: true

  defp actor_edit_view(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.form_state)
      |> assign(assigns.related_state)
      |> assign(assigns.group_membership_state)

    ~H"""
    <Form.panel_header title={"Edit #{@actor.name}"} close_event="cancel_actor_edit_form" />
    <.form
      id="actor-edit-form"
      for={@form}
      phx-change="validate"
      phx-submit="save"
      class="flex flex-col flex-1 min-h-0 overflow-hidden"
    >
      <div class="flex-1 overflow-y-auto px-6 py-5 space-y-5">
        <Form.input
          field={@form[:name]}
          label="Name"
          placeholder="Enter actor name"
          autocomplete="off"
          phx-debounce="300"
          data-1p-ignore
          required
        />
        <Form.input
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
        <.role_picker :if={@actor.type != :service_account} form={@form} is_last_admin={@is_last_admin} />
        <div :if={@actor.type != :service_account}>
          <.otp_toggle id="edit-allow-email-otp-checkbox" form={@form} />
          <p :if={@identities == []} class="mt-1 text-xs text-attn">
            This actor has no SSO identity. Disabling Email OTP will lock them out.
          </p>
        </div>
        <.actor_group_picker
          pending_additions={@pending_group_additions}
          pending_removals={@pending_group_removals}
          current_groups={@groups}
          search_results={@group_search_results}
        />
      </div>
      <Form.panel_footer :if={is_nil(@pending_email_change)}>
        <Form.panel_footer_button type="button" phx-click="cancel_actor_edit_form">
          Cancel
        </Form.panel_footer_button>
        <Form.panel_footer_button type="submit" style="primary">
          Save Changes
        </Form.panel_footer_button>
      </Form.panel_footer>
      <div
        :if={not is_nil(@pending_email_change)}
        class="shrink-0 px-6 py-3 border-t border-attn bg-attn-wash"
      >
        <div class="flex items-start gap-2 mb-3">
          <Core.icon name="ri-alert-line" class="w-4 h-4 text-attn mt-0.5 shrink-0" />
          <div>
            <p class="text-xs font-medium text-attn mb-0.5">
              Changing this actor's email will remove ALL external identities for this actor.
            </p>
            <p class="text-xs text-attn">
              Any active sessions created through these identities will be ended, signing them out immediately. Are you sure?
            </p>
          </div>
        </div>
        <div class="flex items-center justify-end gap-1.5">
          <Form.panel_footer_button type="button" phx-click="cancel_email_change">
            Cancel
          </Form.panel_footer_button>
          <Form.panel_footer_button type="button" phx-click="confirm_email_change" style="danger">
            Yes, change email and clear identities
          </Form.panel_footer_button>
        </div>
      </div>
    </.form>
    """
  end

  attr :account, :any, required: true
  attr :panel, :map, required: true
  attr :form_state, :map, required: true
  attr :token_state, :map, required: true
  attr :group_membership_state, :map, required: true

  defp actor_create_view(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.form_state)
      |> assign(assigns.token_state)
      |> assign(assigns.group_membership_state)

    ~H"""
    <Form.panel_header title={create_title(@new_actor_type)}>
      <:leading>
        <Core.icon
          name={if @new_actor_type == :service_account, do: "ri-robot-3-line", else: "ri-user-add-line"}
          class="w-5 h-5 text-muted"
        />
      </:leading>
    </Form.panel_header>

    <div :if={is_nil(@new_actor_type)} class="flex-1 overflow-y-auto p-6">
      <div class="grid grid-cols-2 gap-3">
        <button
          type="button"
          phx-click="select_new_actor_type"
          phx-value-type="user"
          class="flex flex-col items-center justify-center gap-2 p-5 border border-rule hover:border-fg hover:bg-hover text-center"
        >
          <Core.icon name="ri-user-line" class="w-8 h-8 text-muted" />
          <span class="text-sm font-semibold text-fg">User</span>
          <span class="text-xs text-muted">
            Can sign in to Firezone Client apps or the admin portal
          </span>
        </button>
        <button
          type="button"
          phx-click="select_new_actor_type"
          phx-value-type="service_account"
          class="flex flex-col items-center justify-center gap-2 p-5 border border-rule hover:border-fg hover:bg-hover text-center"
        >
          <Core.icon name="ri-robot-3-line" class="w-8 h-8 text-muted" />
          <span class="text-sm font-semibold text-fg">Service Account</span>
          <span class="text-xs text-muted">Used to authenticate headless Clients</span>
        </button>
      </div>
    </div>

    <.form
      :if={@new_actor_type == :user and @form}
      id="create-user-form"
      for={@form}
      phx-change="validate"
      phx-submit="create_user"
      class="flex flex-col flex-1 min-h-0 overflow-hidden"
    >
      <div class="flex-1 overflow-y-auto px-6 py-5 space-y-5">
        <Form.input
          field={@form[:name]}
          label="Name"
          placeholder="Enter user name"
          autocomplete="off"
          phx-debounce="300"
          data-1p-ignore
          required
        />
        <Form.input
          field={@form[:email]}
          label="Email"
          type="email"
          placeholder="user@example.com"
          autocomplete="off"
          phx-debounce="300"
          data-1p-ignore
          required
        />
        <.role_picker form={@form} is_last_admin={false} />
        <.otp_toggle id="new-allow-email-otp-checkbox" form={@form} />
        <.actor_group_picker
          pending_additions={@pending_group_additions}
          pending_removals={@pending_group_removals}
          current_groups={[]}
          search_results={@group_search_results}
        />
      </div>
      <Form.panel_footer>
        <Form.panel_footer_button type="button" phx-click="close_panel">Cancel</Form.panel_footer_button>
        <Form.panel_footer_button type="submit" style="primary">Create User</Form.panel_footer_button>
      </Form.panel_footer>
    </.form>

    <.form
      :if={@new_actor_type == :service_account and @form}
      id="create-service-account-form"
      for={@form}
      phx-change="validate"
      phx-submit="create_service_account"
      class="flex flex-col flex-1 min-h-0 overflow-hidden"
    >
      <div class="flex-1 overflow-y-auto px-6 py-5 space-y-5">
        <Form.input
          field={@form[:name]}
          label="Name"
          placeholder="E.g. GitHub CI"
          autocomplete="off"
          phx-debounce="300"
          data-1p-ignore
          required
        />
        <div>
          <label class="block text-sm font-medium text-fg mb-2">Token expiration</label>
          <input
            type="date"
            name="token_expiration"
            value={@token_expiration}
            class="block w-full border-rule bg-bg text-fg focus:border-fg focus:ring-0 text-sm"
          />
        </div>
        <.actor_group_picker
          pending_additions={@pending_group_additions}
          pending_removals={@pending_group_removals}
          current_groups={[]}
          search_results={@group_search_results}
        />
      </div>
      <Form.panel_footer>
        <Form.panel_footer_button type="button" phx-click="close_panel">Cancel</Form.panel_footer_button>
        <Form.panel_footer_button type="submit" style="primary">
          Create Service Account
        </Form.panel_footer_button>
      </Form.panel_footer>
    </.form>
    """
  end

  attr :form, :any, required: true
  attr :is_last_admin, :boolean, required: true

  defp role_picker(assigns) do
    ~H"""
    <div>
      <label class="block text-sm font-medium text-fg mb-2">Role</label>
      <div class="grid grid-cols-2 gap-2">
        <div>
          <Form.input
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
              "flex flex-col gap-1 p-3 border border-rule peer-checked:border-fg peer-checked:bg-hover",
              if(@is_last_admin, do: "opacity-50 cursor-not-allowed", else: "cursor-pointer hover:bg-hover")
            ]}
          >
            <span class="flex items-center gap-1.5 text-xs font-semibold text-fg">
              <Core.icon name="ri-user-line" class="w-3.5 h-3.5" /> User
            </span>
            <span class="text-[11px] text-muted">Sign in to Firezone Client apps</span>
          </label>
        </div>
        <div>
          <Form.input
            id={"#{@form[:type].id}--admin"}
            type="radio_button_group"
            field={@form[:type]}
            value="account_admin_user"
            checked={@form[:type].value in [:account_admin_user, "account_admin_user"]}
            disabled={false}
          />
          <label
            for={"#{@form[:type].id}--admin"}
            class="flex flex-col gap-1 p-3 border border-rule cursor-pointer peer-checked:border-fg peer-checked:bg-hover hover:bg-hover"
          >
            <span class="flex items-center gap-1.5 text-xs font-semibold text-fg">
              <Core.icon name="ri-shield-user-line" class="w-3.5 h-3.5" /> Admin
            </span>
            <span class="text-[11px] text-muted">Full access to manage this account</span>
          </label>
        </div>
      </div>
      <p :if={@is_last_admin} class="mt-1 text-xs text-attn">
        Cannot change role. At least one admin must remain in the account.
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :form, :any, required: true

  defp otp_toggle(assigns) do
    ~H"""
    <div id={@id} phx-update="ignore">
      <div class="flex items-center justify-between py-1">
        <div>
          <p class="text-sm font-medium text-fg">Email OTP Sign In</p>
          <p class="text-[11px] text-muted">Allow sign in via one-time email codes</p>
        </div>
        <input type="hidden" name={@form[:allow_email_otp_sign_in].name} value="false" />
        <Core.toggle
          id={@form[:allow_email_otp_sign_in].id}
          name={@form[:allow_email_otp_sign_in].name}
          value="true"
          checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:allow_email_otp_sign_in].value)}
        />
      </div>
    </div>
    """
  end

  attr :pending_additions, :list, default: []
  attr :pending_removals, :list, default: []
  attr :current_groups, :list, default: []
  attr :search_results, :list, default: nil

  defp actor_group_picker(assigns) do
    remove_ids = MapSet.new(assigns.pending_removals)
    {removed_groups, current_groups} = Enum.split_with(assigns.current_groups, &MapSet.member?(remove_ids, &1.group.id))

    assigns =
      assigns
      |> assign(:current_groups, current_groups)
      |> assign(:removed_groups, removed_groups)

    ~H"""
    <div>
      <h3 class="flex items-center gap-1.5 text-sm font-medium text-fg mb-2">
        <Core.icon name="ri-team-line" class="w-4 h-4 text-muted" />
        Groups ({length(@current_groups) + length(@pending_additions)})
      </h3>
      <div class="relative" phx-click-away="blur_group_search">
        <Core.icon
          name="ri-search-line"
          class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3 h-3 text-muted pointer-events-none"
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
          class="w-full pl-7 pr-3 py-1.5 text-sm border border-rule bg-bg text-fg placeholder:text-muted outline-none focus:border-fg"
        />
        <div
          :if={@search_results != nil}
          class="absolute z-10 left-0 right-0 mt-1 bg-bg border border-rule shadow-lg max-h-48 overflow-y-auto"
        >
          <button
            :for={group <- @search_results}
            type="button"
            phx-click="add_pending_group"
            phx-value-group_id={group.id}
            class="w-full text-left px-3 py-2 text-sm text-fg border-b border-hair last:border-b-0 hover:bg-hover"
          >
            {group.name}
          </button>
          <div :if={@search_results == []} class="px-3 py-4 text-center text-xs text-muted">
            No static groups found
          </div>
        </div>
      </div>
      <div class="grid gap-2 mt-2 lg:grid-cols-3">
        <.group_bucket
          title="Current"
          groups={Enum.map(@current_groups, & &1.group)}
          empty_message="No current groups."
          action="add_pending_group_removal"
          action_title="Remove from current groups"
        />
        <.group_bucket
          title="To Add"
          groups={@pending_additions}
          empty_message="No pending additions."
          action="remove_pending_group_addition"
          action_title="Remove from pending additions"
        />
        <.group_bucket
          title="To Remove"
          groups={Enum.map(@removed_groups, & &1.group)}
          empty_message="No pending removals."
          action="undo_pending_group_removal"
          action_title="Remove from pending removals"
        />
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :groups, :list, required: true
  attr :empty_message, :string, required: true
  attr :action, :string, required: true
  attr :action_title, :string, required: true

  defp group_bucket(assigns) do
    ~H"""
    <section class="min-w-0 border border-hair">
      <div class="flex items-center justify-between px-2.5 py-1.5 border-b border-hair">
        <h4 class="text-[11px] font-semibold uppercase tracking-[.12em] text-muted">{@title}</h4>
        <span class="text-[11px] text-muted tabular-nums">{length(@groups)}</span>
      </div>
      <ul :if={@groups != []} class="h-48 overflow-y-auto px-1 py-1">
        <li :for={group <- @groups} class="flex items-center gap-2 px-2 py-1.5 hover:bg-hover">
          <span class="flex-1 text-xs text-fg truncate">{group.name}</span>
          <button
            type="button"
            phx-click={@action}
            phx-value-group_id={group.id}
            class="shrink-0 text-muted hover:text-attn"
            title={@action_title}
          >
            <Core.icon name="ri-close-line" class="w-4 h-4" />
          </button>
        </li>
      </ul>
      <div :if={@groups == []} class="flex items-center justify-center h-16 px-3 text-center">
        <p class="text-xs text-muted">{@empty_message}</p>
      </div>
    </section>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :size, :string, default: "md", values: ~w[md lg]

  @doc """
  The actor's photo, or its type icon when it has none.
  """
  def actor_avatar(assigns) do
    ~H"""
    <.avatar
      account={@account}
      identity_id={@actor.avatar_identity_id}
      etag={@actor.avatar_etag}
      type={@actor.type}
      size={@size}
    />
    """
  end

  attr :account, :any, required: true
  attr :identity_id, :string, default: nil
  attr :etag, :string, default: nil
  attr :type, :atom, default: :account_user
  attr :size, :string, default: "md"

  defp avatar(assigns) do
    assigns =
      assign(
        assigns,
        :photo?,
        not is_nil(assigns.identity_id) and not is_nil(assigns.etag) and Portal.Avatars.enabled?()
      )

    ~H"""
    <div class={["inline-flex shrink-0 rounded-full", avatar_size(@size)]}>
      <img
        :if={@photo?}
        src={~p"/#{@account}/avatars/#{@identity_id}?#{[v: Portal.Avatars.version(@etag)]}"}
        alt=""
        class="size-full rounded-full object-cover bg-hover"
      />
      <div
        :if={not @photo?}
        class="inline-flex items-center justify-center size-full rounded-full bg-hover border border-hair"
      >
        <Core.icon name={actor_type_icon_name(@type)} class={[avatar_icon_size(@size), "text-muted"]} />
      </div>
    </div>
    """
  end

  attr :actor, :any, required: true

  @doc """
  One small logo per identity provider the actor has an identity from.
  """
  def identity_provider_icons(assigns) do
    assigns =
      assign(
        assigns,
        :providers,
        assigns.actor.identity_issuers
        |> Enum.map(&Core.provider_type_from_issuer/1)
        |> Enum.uniq()
      )

    ~H"""
    <span :if={@providers != []} class="inline-flex items-center gap-1 shrink-0">
      <Core.provider_icon :for={provider <- @providers} provider={provider} size="xs" />
    </span>
    <span :if={@providers == []} class="text-xs text-muted">Firezone</span>
    """
  end

  @doc """
  The groups of an actor as a comma list of links, for a list cell.
  """
  attr :account, :any, required: true
  attr :groups, :list, required: true

  def group_links(assigns) do
    {shown, hidden} = Enum.split(assigns.groups, 3)
    assigns = assign(assigns, shown: shown, hidden: length(hidden))

    ~H"""
    <span :if={@groups == []} class="text-muted">None</span>
    <span :if={@groups != []} class="text-muted">
      <%= for {group, index} <- Enum.with_index(@shown) do %>
        {if index > 0, do: ", "}<.link
          navigate={~p"/#{@account}/groups/#{group.id}"}
          phx-click={%JS{}}
          class="text-fg hover:underline"
        >{group.name}</.link>
      <% end %>
      <span :if={@hidden > 0}>+{@hidden}</span>
    </span>
    """
  end

  @doc """
  When the actor was last active, in `attn` when the actor is disabled or idle.
  """
  attr :actor, :any, required: true

  def last_active(assigns) do
    ~H"""
    <span :if={@actor.is_disabled} class="text-attn">Disabled</span>
    <span :if={not @actor.is_disabled and is_nil(@actor.last_seen_at)} class="text-muted">Never</span>
    <span
      :if={not @actor.is_disabled and not is_nil(@actor.last_seen_at)}
      class={if stale?(@actor.last_seen_at), do: "text-attn", else: "text-muted"}
    >
      <Core.relative_datetime datetime={@actor.last_seen_at} popover={false} />
    </span>
    """
  end

  @doc """
  When the newest token of a service account expires.
  """
  attr :tokens, :list, required: true

  def token_expiry(assigns) do
    assigns = assign(assigns, :expires_at, latest_expiry(assigns.tokens))

    ~H"""
    <span :if={@tokens == []} class="text-muted">No token</span>
    <span :if={@tokens != [] and is_nil(@expires_at)} class="text-muted">Token never expires</span>
    <span
      :if={@expires_at && DateTime.compare(@expires_at, DateTime.utc_now()) == :lt}
      class="text-attn"
    >
      Token expired <Core.relative_datetime datetime={@expires_at} popover={false} />
    </span>
    <span :if={@expires_at && DateTime.compare(@expires_at, DateTime.utc_now()) != :lt}>
      Token expires <Core.relative_datetime datetime={@expires_at} popover={false} />
    </span>
    """
  end

  attr :is_disabled, :boolean, required: true
  attr :disabled_by_directory, :boolean, default: false

  def actor_status_badge(assigns) do
    ~H"""
    <Core.status_badge
      style={if @is_disabled, do: :danger, else: :success}
      icon={if @is_disabled and @disabled_by_directory, do: "ri-loop-left-line"}
      icon_title={if @is_disabled and @disabled_by_directory, do: "Disabled by directory sync"}
    >
      {if @is_disabled, do: "Disabled", else: "Active"}
    </Core.status_badge>
    """
  end

  attr :online, :boolean, required: true

  @doc """
  A filled dot when online, a hollow ring when offline.
  """
  def presence_dot(assigns) do
    ~H"""
    <span
      class={[
        "inline-block w-[7px] h-[7px] rounded-full shrink-0",
        if(@online, do: "bg-fg", else: "ring-[1.5px] ring-inset ring-attn")
      ]}
      title={if @online, do: "Online", else: "Offline"}
    >
    </span>
    """
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp eyebrow(assigns) do
    ~H"""
    <h3 class="flex items-center gap-1.5 mb-2.5 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
      <Core.icon name={@icon} class="w-3.5 h-3.5" /> {render_slot(@inner_block)}
    </h3>
    """
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp empty_tab(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-2 h-32 text-sm text-muted">
      <Core.icon name={@icon} class="w-5 h-5 text-faint" />
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :question, :string, required: true
  attr :cancel, :string, required: true
  attr :confirm, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true

  defp confirm_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-2 px-6 py-2.5 bg-attn-wash">
      <span class="text-xs text-fg truncate">
        {@question} <span class="block text-muted">This cannot be undone.</span>
      </span>
      <div class="flex items-center gap-1.5 shrink-0">
        <Form.button type="button" phx-click={@cancel} size="xs">Cancel</Form.button>
        <Form.button type="button" phx-click={@confirm} phx-value-id={@id} style="danger" size="xs">
          {@label}
        </Form.button>
      </div>
    </div>
    """
  end

  attr :confirm, :string, required: true
  attr :id, :string, required: true
  attr :title, :string, required: true

  defp row_actions(assigns) do
    ~H"""
    <div class="flex items-center gap-1 shrink-0">
      <button
        type="button"
        phx-click={@confirm}
        phx-value-id={@id}
        class="flex items-center justify-center w-6 h-6 text-muted hover:text-attn hover:bg-hover"
        title={@title}
      >
        <Core.icon name="ri-delete-bin-line" class="w-3.5 h-3.5" />
      </button>
      <Core.icon name="ri-arrow-down-s-line" class="w-4 h-4 text-muted shrink-0 group-open/details:hidden" />
      <Core.icon
        name="ri-arrow-up-s-line"
        class="w-4 h-4 text-muted shrink-0 hidden group-open/details:block"
      />
    </div>
    """
  end

  slot :inner_block, required: true

  defp detail_grid(assigns) do
    ~H"""
    <div class="pl-16 pr-6 pb-4 pt-1">
      <dl class="grid grid-cols-2 gap-x-6 gap-y-3">
        {render_slot(@inner_block)}
      </dl>
    </div>
    """
  end

  attr :device, :any, required: true
  attr :location, :string, default: nil
  slot :inner_block

  defp session_details(assigns) do
    ~H"""
    <.detail_grid>
      <.detail_field :if={@device && @device.last_seen_remote_ip} label="IP Address" mono>
        {@device.last_seen_remote_ip}
      </.detail_field>
      <.detail_field :if={@location} label="Location">{@location}</.detail_field>
      <.detail_field :if={@device && @device.last_seen_version} label="Client Version">
        {@device.last_seen_version}
      </.detail_field>
      <.detail_field
        :if={@device && @device.last_seen_user_agent}
        label="User Agent"
        title={@device.last_seen_user_agent}
      >
        {@device.last_seen_user_agent}
      </.detail_field>
      <.detail_field :if={@device} label="Last seen">
        <Core.relative_datetime datetime={@device.last_seen_at} />
      </.detail_field>
      {render_slot(@inner_block)}
    </.detail_grid>
    """
  end

  attr :label, :string, required: true
  attr :mono, :boolean, default: false
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp detail_field(assigns) do
    ~H"""
    <div class={@class}>
      <dt class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">{@label}</dt>
      <dd class={["text-sm text-fg truncate mt-0.5", @mono && "font-mono text-xs"]} title={@title}>
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  defp normalize_tab(%{type: :service_account}, _tab), do: "tokens"

  defp normalize_tab(_actor, tab) when tab in ~w[identities client_sessions portal_sessions],
    do: tab

  defp normalize_tab(_actor, _tab), do: "identities"

  defp create_title(:service_account), do: "New service account"
  defp create_title(_type), do: "New person"

  defp manual_group?(group), do: group.type == :static and is_nil(group.idp_id)

  defp stale?(last_seen_at), do: DateTime.diff(DateTime.utc_now(), last_seen_at, :day) > 30

  defp latest_expiry(tokens) do
    tokens
    |> Enum.map(& &1.expires_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp avatar_size("md"), do: "size-8"
  defp avatar_size("lg"), do: "size-12"

  defp avatar_icon_size("md"), do: "size-4"
  defp avatar_icon_size("lg"), do: "size-6"

  defp actor_type_icon_name(:service_account), do: "ri-robot-3-line"
  defp actor_type_icon_name(_type), do: "ri-user-line"

  defp actor_display_type(%{type: :service_account}), do: "Service account"
  defp actor_display_type(%{type: :account_admin_user}), do: "Admin"
  defp actor_display_type(_actor), do: "User"

  defp identity_display_name(identity) do
    full_name = [identity.given_name, identity.family_name] |> Enum.reject(&blank?/1) |> Enum.join(" ")

    Enum.find([identity.name, full_name, identity.email, extract_idp_id(identity.idp_id)], &(not blank?(&1)))
  end

  defp blank?(value), do: is_nil(value) or String.trim(value) == ""

  defp extract_idp_id(idp_id) do
    String.split(idp_id, ":", parts: 2) |> List.last()
  end

  defp token_place(token) do
    token_location(token) || (token.last_used_device && token.last_used_device.last_seen_remote_ip)
  end

  defp token_location(%{last_used_device: nil}), do: nil

  defp token_location(%{last_used_device: device}) do
    cond do
      device.last_seen_remote_ip_location_city && device.last_seen_remote_ip_location_region ->
        "#{device.last_seen_remote_ip_location_city}, #{device.last_seen_remote_ip_location_region}"

      device.last_seen_remote_ip_location_region ->
        device.last_seen_remote_ip_location_region

      true ->
        nil
    end
  end

  @firezone_client_patterns [
    {"Windows/", "icon-os-windows"},
    {"Mac OS/", "icon-os-macos"},
    {"iOS/", "icon-os-ios"},
    {"Android/", "icon-os-android"},
    {"Ubuntu/", "icon-os-ubuntu"},
    {"Debian/", "icon-os-debian"},
    {"Manjaro/", "icon-os-manjaro"},
    {"CentOS/", "icon-os-linux"},
    {"Fedora/", "icon-os-linux"}
  ]

  @browser_patterns [
    {"iPhone", "icon-os-ios"},
    {"iPad", "icon-os-ios"},
    {"Android", "icon-os-android"},
    {"Macintosh", "icon-os-macos"},
    {"Mac OS X", "icon-os-macos"},
    {"Windows NT", "icon-os-windows"},
    {"linux", "icon-os-linux"}
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
      "icon-os-linux"
    end
  end

  # The directory's identity of the actor is kept while the directory has it
  # disabled, so its name is already loaded with the identities.
  defp disabling_directory_name(%{disabled_by_directory_id: nil}, _identities), do: nil

  defp disabling_directory_name(%{disabled_by_directory_id: directory_id}, identities) do
    Enum.find_value(identities, "Directory sync", fn identity ->
      if identity.directory_id == directory_id, do: identity.directory_name
    end)
  end
end
