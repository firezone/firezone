defmodule PortalWeb.Clients.Components do
  use PortalWeb, :component_library
  import PortalWeb.CoreComponents
  alias Portal.ComponentVersions

  def actor_show_url(account, actor, return_to \\ nil)

  def actor_show_url(account, %Portal.Actor{type: :api_client} = _actor, _return_to) do
    ~p"/#{account}/settings/api_clients"
  end

  def actor_show_url(account, actor, return_to) do
    if return_to do
      ~p"/#{account}/actors/#{actor}?#{[return_to: return_to]}"
    else
      ~p"/#{account}/actors/#{actor}"
    end
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :class, :string, default: ""
  attr :return_to, :string, default: nil

  def actor_name_and_role(assigns) do
    ~H"""
    <.link
      navigate={actor_show_url(@account, @actor, @return_to)}
      class={["text-brand hover:underline", @class]}
    >
      {@actor.name}
    </.link>
    <span :if={@actor.type == :account_admin_user} class={["text-xs", @class]}>
      (admin)
    </span>
    <span :if={@actor.type == :service_account} class={["text-xs", @class]}>
      (service account)
    </span>
    <span :if={@actor.type == :api_client} class={["text-xs", @class]}>
      (api client)
    </span>
    """
  end

  defp device_user_agent(device) do
    device.last_seen_user_agent
  end

  def client_os(assigns) do
    assigns = assign(assigns, :user_agent, device_user_agent(assigns.client))

    ~H"""
    <div class="flex items-center text-xs text-body">
      <span class="mr-1 mb-1"><.client_os_icon client={@client} /></span>
      {get_client_os_name_and_version(@user_agent)}
    </div>
    """
  end

  def client_os_icon(assigns) do
    assigns = assign(assigns, :user_agent, device_user_agent(assigns.client))

    ~H"""
    <.icon
      name={client_os_icon_name(@user_agent)}
      title={get_client_os_name_and_version(@user_agent)}
      class="w-5 h-5"
    />
    """
  end

  def client_os_name_and_version(assigns) do
    assigns = assign(assigns, :user_agent, device_user_agent(assigns.client))

    ~H"""
    <span>
      {get_client_os_name_and_version(@user_agent)}
    </span>
    """
  end

  def client_as_icon(assigns) do
    ~H"""
    <.popover placement="right">
      <:target>
        <.client_os_icon client={@client} />
      </:target>
      <:content>
        <div>
          {@client.name}
          <.icon
            :if={trust_state(@client)}
            name={trust_state(@client).icon}
            class="h-2.5 w-2.5 text-neutral-500"
            title={trust_state(@client).title}
          />
        </div>
        <div>
          <.client_os_name_and_version client={@client} />
        </div>
        <div>
          <span>Last started:</span>
          <.relative_datetime
            datetime={@client.last_seen_at}
            popover={false}
          />
        </div>
        <div>
          <.connection_status schema={@client} />
        </div>
      </:content>
    </.popover>
    """
  end

  def client_os_icon_name(nil), do: "ri-computer-line"
  def client_os_icon_name("Windows/" <> _), do: "icon-os-windows"
  def client_os_icon_name("Mac OS/" <> _), do: "icon-os-macos"
  def client_os_icon_name("iOS/" <> _), do: "icon-os-ios"
  def client_os_icon_name("Android/" <> _), do: "icon-os-android"
  def client_os_icon_name("Ubuntu/" <> _), do: "icon-os-ubuntu"
  def client_os_icon_name("Debian/" <> _), do: "icon-os-debian"
  def client_os_icon_name("Manjaro/" <> _), do: "icon-os-manjaro"
  def client_os_icon_name("CentOS/" <> _), do: "icon-os-linux"
  def client_os_icon_name("Fedora/" <> _), do: "icon-os-linux"

  def client_os_icon_name(other) do
    if String.contains?(other, "linux") do
      "icon-os-linux"
    else
      "ri-computer-line"
    end
  end

  @doc """
  Renders a version badge with the current version and icon based on whether the component is outdated.
  """
  attr :current, :string, required: true
  attr :latest, :string

  def version(%{current: nil} = assigns) do
    ~H"""
    <span class="text-xs text-muted">—</span>
    """
  end

  def version(assigns) do
    assigns =
      assign(assigns, outdated?: outdated_version?(assigns.current, assigns.latest))

    ~H"""
    <.popover>
      <:target>
        <span class={[
          "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium font-mono",
          if(@outdated?,
            do: "text-warning bg-warning-light",
            else: "text-success bg-success-light"
          )
        ]}>
          <.icon
            :if={@outdated?}
            name="ri-arrow-up-line"
            class="h-2.5 w-2.5 shrink-0"
          />
          <.icon
            :if={not @outdated?}
            name="ri-check-line"
            class="h-2.5 w-2.5 shrink-0"
          />
          {@current}
        </span>
      </:target>
      <:content>
        <p :if={not @outdated?}>
          This component is up to date.
        </p>
        <p :if={@outdated?}>
          A newer version <.website_link path="/changelog">{@latest}</.website_link> is available.
        </p>
      </:content>
    </.popover>
    """
  end

  defp outdated_version?(current, latest) when is_binary(current) and is_binary(latest) do
    with {:ok, current_version} <- Version.parse(current),
         {:ok, latest_version} <- Version.parse(latest) do
      Version.compare(current_version, latest_version) == :lt
    else
      :error -> false
    end
  end

  defp outdated_version?(_, _), do: false

  attr :account, :any, required: true
  attr :client, :any, required: true
  attr :panel, :map, required: true
  attr :confirm_state, :map, required: true
  attr :query_params, :map, default: %{}
  attr :device_pools, :list, default: []
  attr :posture, :list, default: []
  attr :posture_providers_connected?, :boolean, default: false
  attr :certificate, :map, default: nil
  attr :policy_authorizations, :list, default: []
  attr :policy_authorizations_page, :integer, default: 1
  attr :policy_authorizations_has_next, :boolean, default: false
  attr :policy_authorizations_expanded_id, :string, default: nil

  def client_panel(assigns) do
    assigns =
      assigns
      |> assign(assigns.panel)
      |> assign(assigns.confirm_state)

    ~H"""
    <div
      id="client-panel"
      class={[
        "absolute inset-y-0 right-0 z-10 flex flex-col w-full lg:w-3/4 xl:w-2/3",
        "bg-elevated border-l border-border-strong",
        "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
        "transition-transform duration-200 ease-in-out",
        if(@client, do: "translate-x-0", else: "translate-x-full")
      ]}
      phx-window-keydown="handle_keydown"
      phx-key="Escape"
    >
      <div :if={@client} class="flex flex-col h-full overflow-hidden">
        <.client_edit_view
          :if={@panel_view == :edit_client}
          client_edit_form={@client_edit_form}
        />

        <.client_details_view
          :if={@panel_view != :edit_client}
          account={@account}
          client={@client}
          tab={@panel_tab}
          confirm_delete_client={@confirm_delete_client}
          confirm_unverify_client={@confirm_unverify_client}
          device_pools={@device_pools}
          posture={@posture}
          posture_providers_connected?={@posture_providers_connected?}
          certificate={@certificate}
          policy_authorizations={@policy_authorizations}
          policy_authorizations_page={@policy_authorizations_page}
          policy_authorizations_has_next={@policy_authorizations_has_next}
          policy_authorizations_expanded_id={@policy_authorizations_expanded_id}
        />
      </div>
    </div>
    """
  end

  attr :client_edit_form, :any, default: nil

  def client_edit_view(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0 flex-col overflow-hidden">
      <.panel_header title="Edit Client" close_event="cancel_client_edit_form" />
      <.form
        :if={@client_edit_form}
        id="client-edit-form"
        for={@client_edit_form}
        phx-submit="submit_client_edit_form"
        phx-change="change_client_edit_form"
        class="flex flex-col flex-1 min-h-0 overflow-hidden"
      >
        <.client_edit_form_body client_edit_form={@client_edit_form} />
        <.client_edit_actions />
      </.form>
    </div>
    """
  end

  attr :client_edit_form, :any, required: true

  def client_edit_form_body(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto px-5 py-4 space-y-4">
      <div>
        <label
          for={@client_edit_form[:name].id}
          class="block text-xs font-medium text-body mb-1.5"
        >
          Name <span class="text-error">*</span>
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
    """
  end

  def client_edit_actions(assigns) do
    ~H"""
    <.panel_footer>
      <.panel_footer_button type="button" phx-click="cancel_client_edit_form">
        Cancel
      </.panel_footer_button>
      <.panel_footer_button type="submit" style="primary">
        Save
      </.panel_footer_button>
    </.panel_footer>
    """
  end

  attr :account, :any, required: true
  attr :client, :any, required: true
  attr :tab, :atom, default: :overview
  attr :confirm_delete_client, :boolean, default: false
  attr :confirm_unverify_client, :boolean, default: false
  attr :device_pools, :list, default: []
  attr :posture, :list, default: []
  attr :posture_providers_connected?, :boolean, default: false
  attr :certificate, :map, default: nil
  attr :policy_authorizations, :list, default: []
  attr :policy_authorizations_page, :integer, default: 1
  attr :policy_authorizations_has_next, :boolean, default: false
  attr :policy_authorizations_expanded_id, :string, default: nil

  def client_details_view(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <.client_details_header client={@client} />
      <div class="flex flex-1 min-h-0 divide-x divide-border">
        <div class="flex-1 flex flex-col overflow-hidden">
          <div
            role="tablist"
            class="flex items-end gap-0 px-5 border-b border-border bg-raised shrink-0"
          >
            <.client_tab tab="overview" label="Overview" selected={@tab == :overview} />
            <.client_tab
              tab="authorizations"
              label="Authorizations"
              selected={@tab == :authorizations}
            />
            <.client_tab tab="posture" label="Posture" selected={@tab == :posture} />
          </div>
          <div :if={@tab == :overview} class="flex-1 overflow-y-auto">
            <.client_owner_section account={@account} client={@client} />
            <.client_device_pools_section
              :if={@device_pools != []}
              account={@account}
              device_pools={@device_pools}
            />
            <.client_device_section account={@account} client={@client} />
            <.client_certificate_section
              :if={@client.last_attested_cert_fingerprint}
              client={@client}
              certificate={@certificate}
            />
            <.client_network_section client={@client} />
          </div>
          <.client_posture_tab
            :if={@tab == :posture}
            account={@account}
            posture={@posture}
            providers_connected?={@posture_providers_connected?}
          />
          <.client_policy_authorizations_tab
            :if={@tab == :authorizations}
            account={@account}
            client={@client}
            policy_authorizations={@policy_authorizations}
            page={@policy_authorizations_page}
            has_next={@policy_authorizations_has_next}
            expanded_id={@policy_authorizations_expanded_id}
          />
        </div>
        <.client_sidebar
          client={@client}
          confirm_delete_client={@confirm_delete_client}
          confirm_unverify_client={@confirm_unverify_client}
        />
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :client, :any, required: true
  attr :policy_authorizations, :list, default: []
  attr :page, :integer, default: 1
  attr :has_next, :boolean, default: false
  attr :expanded_id, :string, default: nil

  def client_policy_authorizations_tab(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col overflow-hidden">
      <.authorization_flow_logs_notice account={@account} />
      <div
        :if={@policy_authorizations == []}
        class="flex flex-1 flex-col items-center justify-center gap-2 text-subtle"
      >
        <.icon name="ri-shield-check-line" class="w-8 h-8" />
        <p class="text-sm">No recent authorizations</p>
      </div>
      <div :if={@policy_authorizations != []} class="flex-1 flex flex-col overflow-hidden">
        <div class="flex-1 overflow-y-auto">
          <table class="w-full text-xs">
            <thead class="sticky top-0 bg-surface z-10">
              <tr class="border-b border-border text-subtle">
                <th class="text-left px-4 py-2 font-medium">Resource</th>
                <th class="text-left px-4 py-2 font-medium">Group</th>
                <th class="text-left px-4 py-2 font-medium">Authorized</th>
                <th class="text-left px-4 py-2 font-medium">Expires</th>
                <th class="w-6"></th>
              </tr>
            </thead>
            <tbody>
              <%= for row <- @policy_authorizations do %>
                <tr
                  phx-click="toggle_policy_authorization_row"
                  phx-keydown="toggle_policy_authorization_row"
                  phx-key="Enter"
                  phx-value-id={row.authorization.id}
                  tabindex="0"
                  class="border-b border-border hover:bg-raised cursor-pointer focus:outline-none focus:bg-raised"
                >
                  <td class="px-4 py-2 text-heading">
                    {row.resource.name}
                  </td>
                  <td class="px-4 py-2 text-body">
                    {if row.group, do: row.group.name, else: "Everyone"}
                  </td>
                  <td class="px-4 py-2 text-subtle">
                    <.relative_datetime datetime={row.authorization.inserted_at} />
                  </td>
                  <td class="px-4 py-2 text-subtle">
                    <.relative_datetime datetime={row.authorization.expires_at} />
                  </td>
                  <td class="px-4 py-2 text-subtle">
                    <.icon
                      name={
                        if @expanded_id == row.authorization.id,
                          do: "ri-arrow-up-s-line",
                          else: "ri-arrow-down-s-line"
                      }
                      class="w-4 h-4"
                    />
                  </td>
                </tr>
                <tr
                  :if={@expanded_id == row.authorization.id}
                  class="border-b border-border bg-raised"
                >
                  <td colspan="5" class="px-4 py-3">
                    <div class="grid grid-cols-2 gap-x-8 gap-y-2 text-xs">
                      <div>
                        <p class="text-subtle font-medium mb-1">
                          {case row.initiating_device && row.initiating_device.type do
                            :gateway -> "Initiator (Gateway)"
                            :client -> "Initiator (Client)"
                            _ -> "Initiator"
                          end}
                        </p>
                        <p class="text-heading">
                          {if row.initiating_device, do: row.initiating_device.name, else: "—"}
                        </p>
                        <p class="text-subtle font-mono mt-0.5">
                          {if row.authorization.initiator_remote_ip,
                            do: Portal.Types.INET.to_string(row.authorization.initiator_remote_ip),
                            else: "—"}
                        </p>
                      </div>
                      <div>
                        <p class="text-subtle font-medium mb-1">
                          {case row.receiving_device && row.receiving_device.type do
                            :gateway -> "Receiver (Gateway)"
                            :client -> "Receiver (Client)"
                            _ -> "Receiver"
                          end}
                        </p>
                        <p class="text-heading">
                          {if row.receiving_device, do: row.receiving_device.name, else: "—"}
                        </p>
                        <p class="text-subtle font-mono mt-0.5">
                          {if row.authorization.receiver_remote_ip,
                            do: Portal.Types.INET.to_string(row.authorization.receiver_remote_ip),
                            else: "—"}
                        </p>
                      </div>
                      <div>
                        <p class="text-subtle font-medium mb-1">Owner</p>
                        <p class="text-heading">
                          {if @client.actor, do: @client.actor.name, else: "—"}
                        </p>
                      </div>
                      <div>
                        <p class="text-subtle font-medium mb-1">Policy</p>
                        <.link
                          navigate={~p"/#{@account}/policies/#{row.authorization.policy_id}"}
                          class="text-brand hover:underline"
                        >
                          {if row.group, do: row.group.name, else: "Everyone"} → {row.resource.name}
                        </.link>
                      </div>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        <div class="flex items-center justify-between px-4 py-2 border-t border-border shrink-0">
          <button
            phx-click="change_policy_authorizations_page"
            phx-value-page={@page - 1}
            disabled={@page == 1}
            class="flex items-center gap-1 text-xs transition-colors disabled:text-muted disabled:cursor-not-allowed text-body hover:enabled:text-heading"
          >
            <.icon name="ri-arrow-left-s-line" class="w-4 h-4" /> Previous
          </button>
          <span class="text-xs text-subtle">Page {@page}</span>
          <button
            phx-click="change_policy_authorizations_page"
            phx-value-page={@page + 1}
            disabled={not @has_next}
            class="flex items-center gap-1 text-xs transition-colors disabled:text-muted disabled:cursor-not-allowed text-body hover:enabled:text-heading"
          >
            Next <.icon name="ri-arrow-right-s-line" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :client, :any, required: true

  def client_details_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 py-4 border-b border-border bg-elevated">
      <div class="flex items-center gap-4">
        <%!-- Left: name + status + ID --%>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-semibold text-heading truncate">{@client.name}</h2>
            <.client_status_badge online?={@client.online?} />
            <.client_verified_badge client={@client} />
          </div>
          <p class="font-mono text-xs text-subtle mt-0.5 truncate">{@client.id}</p>
        </div>
        <%!-- Right: actions --%>
        <div class="flex items-center gap-1.5 shrink-0">
          <.button phx-click="open_client_edit_form" size="xs">
            <.icon name="ri-pencil-line" class="w-3.5 h-3.5" /> Edit
          </.button>
          <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
        </div>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :client, :any, required: true

  def client_owner_section(assigns) do
    ~H"""
    <div class="px-5 pt-4 pb-3 border-b border-border">
      <.section_heading title="Owner" />
      <.link
        navigate={~p"/#{@account}/actors/#{@client.actor.id}"}
        class="flex items-center gap-3 px-3 py-2.5 rounded border border-border bg-raised hover:border-border-strong transition-colors group"
      >
        <div class="flex items-center justify-center w-8 h-8 rounded-full shrink-0 text-xs font-semibold bg-brand-muted text-brand">
          {String.slice(@client.actor.name, 0, 2) |> String.upcase()}
        </div>
        <div class="min-w-0">
          <p class="text-sm font-medium text-heading group-hover:text-brand truncate transition-colors">
            {@client.actor.name}
          </p>
          <p :if={@client.actor.email} class="text-xs text-subtle truncate">
            {@client.actor.email}
          </p>
        </div>
      </.link>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :device_pools, :list, required: true

  def client_device_pools_section(assigns) do
    ~H"""
    <div class="px-5 pt-4 pb-3 border-b border-border">
      <.section_heading title="Device Pools" />
      <p class="mb-2 text-xs text-subtle">
        Anyone granted access to these pools can reach this Client directly on its tunnel address.
      </p>
      <ul class="space-y-1">
        <li :for={pool <- @device_pools}>
          <.link
            navigate={~p"/#{@account}/resources/#{pool.id}"}
            class="flex items-center gap-2 px-3 py-2 rounded border border-border bg-raised hover:border-border-strong transition-colors group"
          >
            <.icon name="ri-computer-line" class="w-4 h-4 shrink-0 text-subtle" />
            <span class="text-sm text-heading group-hover:text-brand truncate transition-colors">
              {pool.name}
            </span>
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :client, :any, required: true

  def client_device_section(assigns) do
    ~H"""
    <div class="px-5 pt-4 pb-3 border-b border-border">
      <.section_heading title="Reported by this Client" />
      <p class="mb-3 text-xs text-subtle">
        The Firezone Client reports these fields about itself, so a malicious actor could spoof
        them.
        <span :if={is_nil(@client.last_attested_at)}>
          Set up
          <.link
            navigate={~p"/#{@account}/settings/trust_anchors"}
            class="text-brand hover:underline"
          >
            X.509 Device Trust
          </.link>
          to strongly identify this device and associate it with posture data.
        </span>
      </p>
      <dl class="space-y-3">
        <.client_detail_row :if={@client.last_seen_at} label="Operating System">
          <.client_os client={@client} />
        </.client_detail_row>
        <.client_detail_row :if={@client.device_serial} label="Serial Number">
          <span class="font-mono text-sm text-heading font-medium">
            {@client.device_serial}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.device_uuid} label="Device UUID">
          <span class="font-mono text-xs text-body break-all">
            {@client.device_uuid}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.identifier_for_vendor} label="App Installation ID">
          <span class="font-mono text-xs text-body break-all">
            {@client.identifier_for_vendor}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.firebase_installation_id} label="App Installation ID">
          <span class="font-mono text-xs text-body break-all">
            {@client.firebase_installation_id}
          </span>
        </.client_detail_row>
      </dl>
    </div>
    """
  end

  attr :client, :any, required: true

  def client_network_section(assigns) do
    ~H"""
    <div class="px-5 pt-4 pb-3">
      <.section_heading title="Network" />
      <dl class="space-y-3">
        <.client_detail_row :if={@client.last_seen_remote_ip} label="Remote IP">
          <span class="text-xs text-body">
            <.last_seen schema={@client} />
          </span>
        </.client_detail_row>
        <.client_detail_row label="Tunnel IPv4">
          <span class="font-mono text-xs text-body">
            {@client.ipv4}
          </span>
        </.client_detail_row>
        <.client_detail_row label="Tunnel IPv6">
          <span class="font-mono text-xs text-body break-all">
            {@client.ipv6}
          </span>
        </.client_detail_row>
      </dl>
    </div>
    """
  end

  attr :tab, :string, required: true
  attr :label, :string, required: true
  attr :selected, :boolean, required: true

  def client_tab(assigns) do
    ~H"""
    <button
      role="tab"
      aria-selected={@selected}
      phx-click="switch_client_tab"
      phx-value-tab={@tab}
      class={[
        "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
        if(@selected,
          do: "border-brand text-brand",
          else: "border-transparent text-body hover:text-heading"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :account, :any, required: true
  attr :posture, :list, required: true
  attr :providers_connected?, :boolean, default: false

  def client_posture_tab(assigns) do
    assigns = assign(assigns, :state, posture_tab_state(assigns))

    ~H"""
    <div class="flex-1 overflow-y-auto">
      <div :if={@state == :records}>
        <.client_posture_section :for={entry <- @posture} account={@account} entry={entry} />
      </div>
      <.posture_locked :if={@state == :locked} account={@account} />
      <div
        :if={@state in [:no_records, :no_providers]}
        class="flex flex-col items-center justify-center gap-2 px-5 py-16 text-center text-subtle"
      >
        <.icon name="ri-shield-star-line" class="w-8 h-8" />
        <p :if={@state == :no_records} class="text-xs">
          No posture data was found for this device.
        </p>
        <p :if={@state == :no_providers} class="text-xs">
          <.link
            navigate={~p"/#{@account}/settings/device_posture/new"}
            class="text-brand hover:underline"
          >
            Connect a posture provider
          </.link>
          to view posture data for this device.
        </p>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :entry, :map, required: true

  def client_posture_section(assigns) do
    assigns =
      assigns
      |> assign(:attributes, posture_attributes(assigns.entry.type, assigns.entry.device))
      |> assign(:dom_id, "posture-#{assigns.entry.type}-#{assigns.entry.provider.id}")

    ~H"""
    <div class="px-5 pt-4 pb-3 border-b border-border">
      <div class="flex items-center justify-between gap-3 mb-3">
        <div class="flex items-center gap-2 min-w-0">
          <.provider_icon provider={to_string(@entry.type)} size="sm" />
          <span class="text-sm font-medium text-heading truncate">{@entry.provider.name}</span>
          <span class="text-xs text-subtle shrink-0">
            {posture_provider_label(@entry.type)}
          </span>
        </div>
        <.posture_match_badge account={@account} matched_on={@entry.matched_on} via={@entry.via} />
      </div>

      <dl class="grid grid-cols-2 gap-x-6 gap-y-3 mb-4">
        <.client_detail_row :for={{label, value} <- @attributes} label={label}>
          <.posture_value value={value} />
        </.client_detail_row>
      </dl>

      <.json_view
        id={@dom_id}
        value={posture_record(@entry.device)}
        label="Provider record"
        hint="Empty fields omitted"
      />
    </div>
    """
  end

  attr :account, :any, required: true
  attr :matched_on, :atom, required: true
  attr :via, :atom, default: nil

  def posture_match_badge(%{matched_on: :device_serial} = assigns) do
    ~H"""
    <.popover placement="left">
      <:target>
        <span class="inline-flex shrink-0 items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-warning bg-warning-light">
          <.icon name="ri-error-warning-line" class="w-2.5 h-2.5" /> Reported serial
        </span>
      </:target>
      <:content>
        <p>
          Matched on the serial number the device reports about itself. This field could be
          spoofed by a malicious actor.
        </p>
        <p :if={@via == :intune} class="mt-1">
          Reached through the Microsoft Intune record that serial matched, which holds the same
          Entra device ID as this machine.
        </p>
        <p class="mt-1">
          Set up
          <.link
            navigate={~p"/#{@account}/settings/trust_anchors"}
            class="text-brand hover:underline"
          >
            X.509 Device Trust
          </.link>
          so devices prove their identity with an MDM-issued certificate instead.
        </p>
      </:content>
    </.popover>
    """
  end

  def posture_match_badge(assigns) do
    assigns = assign(assigns, :label, posture_match_label(assigns.matched_on))

    ~H"""
    <.popover placement="left">
      <:target>
        <span class="inline-flex shrink-0 items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-success bg-success-light">
          <.icon name="ri-shield-keyhole-line" class="w-2.5 h-2.5" />{@label}
        </span>
      </:target>
      <:content>
        <p>Matched on an identifier this device proved with an MDM-issued device certificate.</p>
        <p :if={@via == :intune} class="mt-1">
          Reached through the Microsoft Intune record for that identifier, which holds the same
          Entra device ID as this machine.
        </p>
      </:content>
    </.popover>
    """
  end

  attr :value, :any, required: true

  def posture_value(%{value: value} = assigns) when is_struct(value, DateTime) do
    ~H"""
    <span class="text-xs text-body">
      <.relative_datetime datetime={@value} />
    </span>
    """
  end

  def posture_value(%{value: value} = assigns) when is_boolean(value) do
    ~H"""
    <span class="text-xs text-body">{if @value, do: "Yes", else: "No"}</span>
    """
  end

  def posture_value(assigns) do
    ~H"""
    <span class="font-mono text-xs text-body break-all">{@value}</span>
    """
  end

  attr :serial, :map, default: nil

  def client_serial(%{serial: nil} = assigns) do
    ~H"""
    <span class="text-xs text-muted">—</span>
    """
  end

  def client_serial(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <.popover :if={@serial.source != :reported} placement="right">
        <:target>
          <.provider_icon :if={@serial.provider} provider={to_string(@serial.provider)} size="xs" />
          <.icon
            :if={is_nil(@serial.provider)}
            name="ri-shield-keyhole-line"
            class="w-3 h-3 shrink-0 text-success"
          />
        </:target>
        <:content>{serial_source_hint(@serial)}</:content>
      </.popover>
      <span class="font-mono text-xs text-body truncate">{@serial.value}</span>
    </div>
    """
  end

  attr :client, :any, required: true
  attr :certificate, :map, default: nil

  def client_certificate_section(assigns) do
    assigns = assign(assigns, :issuer, describe_issuer(assigns.client.last_attested_cert_issuer))

    ~H"""
    <div class="px-5 pt-4 pb-3 border-b border-border">
      <.section_heading title="Certificate" />
      <dl class="space-y-3">
        <.client_detail_row label="Status">
          <.certificate_status_badge certificate={@certificate} />
        </.client_detail_row>
        <.client_detail_row :if={@issuer} label="Issuer">
          <span class="text-xs text-body break-all">{@issuer}</span>
        </.client_detail_row>
        <.client_detail_row :if={@client.last_attested_cert_serial} label="Serial">
          <span class="font-mono text-xs text-body break-all">
            {@client.last_attested_cert_serial}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.last_attested_cert_fingerprint} label="SHA-256 Fingerprint">
          <span class="font-mono text-xs text-body break-all">
            {@client.last_attested_cert_fingerprint}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@certificate && @certificate.revoked_at} label="Revoked">
          <span class="text-xs text-body">
            <.relative_datetime datetime={@certificate.revoked_at} />
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@certificate && @certificate.reason} label="Revocation Reason">
          <span class="text-xs text-body">{@certificate.reason}</span>
        </.client_detail_row>
        <.client_detail_row :if={@client.last_attested_at} label="Last Attested">
          <span class="text-xs text-body">
            <.relative_datetime datetime={@client.last_attested_at} />
          </span>
        </.client_detail_row>
      </dl>
    </div>
    """
  end

  attr :certificate, :map, default: nil

  def certificate_status_badge(%{certificate: %{state: :revoked}} = assigns) do
    ~H"""
    <.popover>
      <:target>
        <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-error bg-error-light">
          <.icon name="ri-close-circle-line" class="w-2.5 h-2.5" /> Revoked
        </span>
      </:target>
      <:content>
        {certificate_source_label(@certificate.source)} reports this certificate as revoked.
      </:content>
    </.popover>
    """
  end

  def certificate_status_badge(%{certificate: %{state: :good}} = assigns) do
    ~H"""
    <.popover>
      <:target>
        <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-success bg-success-light">
          <.icon name="ri-check-line" class="w-2.5 h-2.5" /> Valid
        </span>
      </:target>
      <:content>
        <p>The issuer's OCSP responder reports this certificate as good.</p>
        <p :if={@certificate.next_update} class="mt-1">
          That answer stands until
          <.relative_datetime datetime={@certificate.next_update} popover={false} />.
        </p>
      </:content>
    </.popover>
    """
  end

  def certificate_status_badge(assigns) do
    ~H"""
    <.popover>
      <:target>
        <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-muted bg-raised">
          <.icon name="ri-question-line" class="w-2.5 h-2.5" /> Unknown
        </span>
      </:target>
      <:content>
        Neither a published revocation list nor an OCSP responder has said anything about this
        certificate.
      </:content>
    </.popover>
    """
  end

  attr :client, :any, required: true
  attr :confirm_delete_client, :boolean, default: false
  attr :confirm_unverify_client, :boolean, default: false

  def client_sidebar(assigns) do
    ~H"""
    <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
      <.client_details_card client={@client} />
      <div class="border-t border-border"></div>
      <.client_actions client={@client} confirm_unverify_client={@confirm_unverify_client} />
      <div class="border-t border-border"></div>
      <.client_danger_zone confirm_delete_client={@confirm_delete_client} />
    </div>
    """
  end

  attr :client, :any, required: true

  def client_details_card(assigns) do
    ~H"""
    <section>
      <.section_heading title="Details" />
      <dl class="space-y-2.5">
        <.client_detail_row label="Client ID">
          <span class="font-mono text-[11px] text-body break-all">
            {@client.id}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.firezone_id} label="Firezone ID">
          <span class="font-mono text-[11px] text-body break-all">
            {@client.firezone_id}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.last_attested_mdm_device_id} label="MDM Device ID">
          <span class="font-mono text-[11px] text-body break-all">
            {@client.last_attested_mdm_device_id}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.last_attested_device_serial} label="Attested Serial">
          <span class="font-mono text-[11px] text-body break-all">
            {@client.last_attested_device_serial}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.last_attested_device_uuid} label="Attested UUID">
          <span class="font-mono text-[11px] text-body break-all">
            {@client.last_attested_device_uuid}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.last_attested_at} label="Last Attested">
          <span class="inline-flex items-center gap-1 text-xs text-body">
            <.icon name="ri-shield-keyhole-line" class="w-3 h-3 text-success" />
            <.relative_datetime datetime={@client.last_attested_at} />
          </span>
        </.client_detail_row>
        <.client_detail_row label="Verification">
          <.client_verified_status client={@client} />
        </.client_detail_row>
        <.client_detail_row label="Version">
          <.version
            current={@client.last_seen_version}
            latest={ComponentVersions.client_version(@client)}
          />
        </.client_detail_row>
        <.client_detail_row label="Last Seen">
          <span class="text-xs text-body">
            <.relative_datetime datetime={@client.last_seen_at} />
          </span>
        </.client_detail_row>
        <.client_detail_row label="Created">
          <span class="text-xs text-body">
            <.relative_datetime datetime={@client.inserted_at} />
          </span>
        </.client_detail_row>
      </dl>
    </section>
    """
  end

  attr :client, :any, required: true
  attr :confirm_unverify_client, :boolean, default: false

  def client_actions(assigns) do
    assigns = assign(assigns, :action, client_action(assigns))

    ~H"""
    <section>
      <.section_heading title="Actions" />
      <div class="space-y-1.5">
        <.popover :if={@action in [:attested_verify, :attested_unverify]} class="block" placement="left">
          <:target>
            <.action_button
              icon={attested_action_icon(@action)}
              disabled
              class="opacity-50 cursor-not-allowed"
            >
              {attested_action_label(@action)}
            </.action_button>
          </:target>
          <:content>
            This device is already attested through X.509 Device Trust.
          </:content>
        </.popover>
        <.action_button
          :if={@action == :verify}
          icon="ri-shield-check-line"
          phx-click="verify_client"
        >
          Verify
        </.action_button>
        <.action_button
          :if={@action == :unverify}
          icon="ri-prohibited-line"
          phx-click="confirm_unverify_client"
        >
          Revoke verification
        </.action_button>
        <div
          :if={@action == :confirm_unverify}
          class="px-3 py-2.5 rounded border border-border bg-raised"
        >
          <p class="text-xs font-medium text-heading mb-1">
            Revoke verification for this client?
          </p>
          <p class="text-xs text-body mb-3">
            Current authorizations for this client may be revoked.
          </p>
          <div class="flex items-center gap-1.5">
            <.button type="button" phx-click="cancel_unverify_client" size="xs">
              Cancel
            </.button>
            <.button type="button" phx-click="unverify_client" size="xs">
              Unverify
            </.button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :confirm_delete_client, :boolean, default: false

  def client_danger_zone(assigns) do
    ~H"""
    <section>
      <h3 class="text-[10px] font-semibold tracking-widest uppercase text-error/60 mb-3">
        Danger Zone
      </h3>
      <button
        :if={not @confirm_delete_client}
        type="button"
        phx-click="confirm_delete_client"
        class="w-full flex items-center gap-2 px-3 py-2 rounded border border-error/20 text-xs text-error hover:bg-error-light transition-colors"
      >
        <.icon name="ri-delete-bin-line" class="w-4 h-4 shrink-0" /> Delete client
      </button>
      <div
        :if={@confirm_delete_client}
        class="px-3 py-2.5 rounded border border-error/20 bg-error-light"
      >
        <p class="text-xs font-medium text-error mb-1">
          Delete this client?
        </p>
        <p class="text-xs text-error/70 mb-3">
          This won't prevent the owner from signing in again; to block access, disable the owning actor instead.
        </p>
        <div class="flex items-center gap-1.5">
          <.button type="button" phx-click="cancel_delete_client" size="xs">
            Cancel
          </.button>
          <.button type="button" phx-click="delete_client" style="danger" size="xs">
            Delete
          </.button>
        </div>
      </div>
    </section>
    """
  end

  attr :client, :any, required: true

  def client_verified_badge(assigns) do
    assigns = assign(assigns, :trust, trust_state(assigns.client))

    ~H"""
    <span
      :if={@trust}
      class={[
        "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium",
        @trust.class
      ]}
      title={@trust.title}
    >
      <.icon name={@trust.icon} class="w-2.5 h-2.5" />{@trust.label}
    </span>
    """
  end

  attr :client, :any, required: true

  def client_verified_status(assigns) do
    assigns = assign(assigns, :trust, trust_state(assigns.client))

    ~H"""
    <span
      :if={@trust}
      class={[
        "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium",
        @trust.class
      ]}
      title={@trust.title}
    >
      <.icon name={@trust.icon} class="w-2.5 h-2.5" />{@trust.label}
    </span>
    <span
      :if={is_nil(@trust)}
      class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-muted bg-raised"
    >
      Unverified
    </span>
    """
  end

  attr :title, :string, required: true

  def section_heading(assigns) do
    ~H"""
    <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-3">
      {@title}
    </h3>
    """
  end

  slot :inner_block, required: true
  attr :label, :string, required: true

  def client_detail_row(assigns) do
    ~H"""
    <div>
      <dt class="text-[10px] text-subtle mb-0.5">{@label}</dt>
      <dd>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :online?, :boolean, required: true

  def client_status_badge(assigns) do
    ~H"""
    <.status_badge style={if @online?, do: :success, else: :neutral}>
      {if @online?, do: "Online", else: "Offline"}
    </.status_badge>
    """
  end

  # This is more complex than it needs to be, but
  # connlib can send "Mac OS" (with a space) violating the User-Agent spec
  def get_client_os_name_and_version(nil), do: ""

  def get_client_os_name_and_version(user_agent) do
    String.split(user_agent, " ")
    |> Enum.reduce_while("", fn component, acc ->
      if String.contains?(component, "/") do
        {:halt, "#{acc} #{String.replace(component, "/", " ")}"}
      else
        {:cont, "#{acc} #{component}"}
      end
    end)
  end

  # Attestation supersedes manual verification: a device that proved possession
  # of an MDM-issued certificate does not need an admin vouching for the
  # attributes it self-reports.
  defp trust_state(%{last_attested_at: attested_at}) when not is_nil(attested_at) do
    %{
      label: "Attested",
      icon: "ri-shield-keyhole-line",
      class: "text-success bg-success-light",
      title: "This device proved possession of an MDM-issued client certificate"
    }
  end

  defp trust_state(%{verified_at: verified_at}) when not is_nil(verified_at) do
    %{
      label: "Verified",
      icon: "ri-shield-check-line",
      class: "text-success bg-success-light",
      title: "Device attributes of this client are manually verified"
    }
  end

  defp trust_state(_client), do: nil

  attr :account, :any, required: true

  defp posture_locked(assigns) do
    ~H"""
    <div class="px-5 py-4">
      <.upgrade_locked_section
        account={@account}
        message="Upgrade to unlock Device Posture"
        description="See what your MDM and EDR hold for this device, matched to the identity its certificate proved."
      >
        <.posture_preview />
      </.upgrade_locked_section>
    </div>
    """
  end

  defp posture_preview(assigns) do
    assigns = assign(assigns, :samples, posture_preview_samples())

    ~H"""
    <div class="space-y-4">
      <div :for={sample <- @samples}>
        <div class="flex items-center justify-between gap-3 mb-3">
          <div class="flex items-center gap-2">
            <.provider_icon provider={sample.provider} size="sm" />
            <span class="text-sm font-medium text-heading">{sample.name}</span>
          </div>
          <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-success bg-success-light">
            <.icon name="ri-shield-keyhole-line" class="w-2.5 h-2.5" /> Attested device ID
          </span>
        </div>
        <dl class="grid grid-cols-2 gap-x-6 gap-y-3">
          <.client_detail_row :for={{label, value} <- sample.attributes} label={label}>
            <span class="font-mono text-xs text-body">{value}</span>
          </.client_detail_row>
        </dl>
      </div>
    </div>
    """
  end

  # Attestation supersedes manual verification, so an attested device offers the
  # button it would otherwise offer, disabled, rather than hiding it.
  defp client_action(%{client: %{last_attested_at: at, verified_at: nil}}) when not is_nil(at),
    do: :attested_verify

  defp client_action(%{client: %{last_attested_at: at}}) when not is_nil(at),
    do: :attested_unverify

  defp client_action(%{client: %{verified_at: nil}}), do: :verify
  defp client_action(%{confirm_unverify_client: true}), do: :confirm_unverify
  defp client_action(_assigns), do: :unverify

  defp attested_action_icon(:attested_verify), do: "ri-shield-check-line"
  defp attested_action_icon(_action), do: "ri-prohibited-line"

  defp attested_action_label(:attested_verify), do: "Verify"
  defp attested_action_label(_action), do: "Revoke verification"

  defp posture_tab_state(assigns) do
    cond do
      not Portal.Account.device_posture_enabled?(assigns.account) -> :locked
      assigns.posture != [] -> :records
      assigns.providers_connected? -> :no_records
      true -> :no_providers
    end
  end

  defp posture_preview_samples do
    [
      %{
        provider: "intune",
        name: "Microsoft Intune",
        attributes: [
          {"Device name", "DESKTOP-4KJ21"},
          {"Serial number", "5CD2419T7K"},
          {"Compliance", "compliant"},
          {"Encrypted", "Yes"}
        ]
      },
      %{
        provider: "defender",
        name: "Microsoft Defender",
        attributes: [
          {"Sensor health", "Active"},
          {"Risk score", "Low"},
          {"Exposure level", "Low"},
          {"Agent version", "10.8760.19041"}
        ]
      }
    ]
  end

  defp serial_source_hint(%{source: :attested}) do
    "The serial number this device proved with an MDM-issued device certificate."
  end

  defp serial_source_hint(%{source: :mdm, provider: provider}) do
    "#{posture_provider_label(provider)} holds this serial number for the device ID " <>
      "this device proved with its certificate."
  end

  defp posture_provider_label(:intune), do: "Microsoft Intune"
  defp posture_provider_label(:iru), do: "Iru"
  defp posture_provider_label(:defender), do: "Microsoft Defender"
  defp posture_provider_label(:santa), do: "Santa"
  defp posture_provider_label(:sentinelone), do: "SentinelOne"

  defp posture_match_label(:mdm_device_id), do: "Attested device ID"
  defp posture_match_label(:attested_serial), do: "Attested serial"

  defp certificate_source_label(:crl), do: "The issuer's revocation list"
  defp certificate_source_label(:ocsp), do: "The issuer's OCSP responder"

  defp describe_issuer(nil), do: nil
  defp describe_issuer(issuer_der), do: Portal.Crypto.X509.describe_name(issuer_der)

  # The handful of columns worth reading at a glance. Everything the provider
  # reported is in the JSON blob underneath, so this list stays short and is
  # ordered identity first, posture second.
  defp posture_attributes(:intune, device) do
    drop_empty([
      {"Device name", device.device_name},
      {"Serial number", device.serial_number},
      {"Compliance", device.compliance_state},
      {"Operating system", join_present([device.operating_system, device.os_version])},
      {"Model", join_present([device.manufacturer, device.model])},
      {"Primary user", device.user_principal_name},
      {"Ownership", device.managed_device_owner_type},
      {"Encrypted", device.is_encrypted},
      {"Intune ID", device.intune_id},
      {"Entra device ID", device.entra_device_id},
      {"Last check-in", device.last_sync_at},
      {"Last synced", device.synced_at}
    ])
  end

  defp posture_attributes(:iru, device) do
    drop_empty([
      {"Device name", device.device_name},
      {"Serial number", device.serial_number},
      {"Model", device.model_name || device.model},
      {"Operating system", join_present([device.os_name || device.platform, device.os_version])},
      {"User", device.user_email || device.user_name},
      {"Blueprint", device.blueprint_name},
      {"MDM enrolled", device.mdm_enabled},
      {"FileVault", device.filevault_enabled},
      {"Agent version", device.agent_version},
      {"Iru ID", device.iru_id},
      {"Last check-in", device.last_check_in_at},
      {"Last synced", device.synced_at}
    ])
  end

  defp posture_attributes(:defender, device) do
    drop_empty([
      {"DNS name", device.computer_dns_name},
      {"Operating system", join_present([device.os_platform, device.version])},
      {"Sensor health", device.health_status},
      {"Onboarding", device.onboarding_status},
      {"Risk score", device.risk_score},
      {"Exposure level", device.exposure_level},
      {"Managed by", device.managed_by},
      {"Agent version", device.agent_version},
      {"Defender ID", device.defender_id},
      {"Entra device ID", device.entra_device_id},
      {"Last seen", device.last_seen_at},
      {"Last synced", device.synced_at}
    ])
  end

  defp posture_attributes(:santa, device) do
    drop_empty([
      {"Hostname", device.hostname},
      {"Serial number", device.serial_number},
      {"Model", device.machine_model},
      {"Operating system", join_present([device.os_type, device.os_version])},
      {"Client mode", device.last_seen_client_mode || device.configured_client_mode},
      {"Primary user", device.primary_user},
      {"Santa version", device.santa_version},
      {"Santa ID", device.santa_id},
      {"Last sync", device.last_sync_at},
      {"Last synced", device.synced_at}
    ])
  end

  defp posture_attributes(:sentinelone, device) do
    drop_empty([
      {"Computer name", device.computer_name},
      {"Serial number", device.serial_number},
      {"Model", device.model_name},
      {"Operating system", join_present([device.os_name, device.os_revision])},
      {"Agent version", device.agent_version},
      {"Network status", device.network_status},
      {"Infected", device.infected},
      {"Active threats", device.active_threats},
      {"Last logged in user", device.last_logged_in_user_name},
      {"Site", device.site_name},
      {"SentinelOne UUID", device.uuid},
      {"Last active", device.last_active_at},
      {"Last synced", device.synced_at}
    ])
  end

  # Everything the provider reported about the device, for copying into a
  # ticket. Columns it left empty are dropped rather than rendered as a wall of
  # nulls above the ones it filled in, and the two keys that are Firezone's own
  # bookkeeping rather than the provider's data go with them.
  defp posture_record(device) do
    device
    |> PortalWeb.JSONComponents.encodable()
    |> Map.drop(["account_id", "posture_provider_id"])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp drop_empty(attributes) do
    Enum.reject(attributes, fn {_label, value} -> value in [nil, ""] end)
  end

  defp join_present(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      joined -> joined
    end
  end
end
