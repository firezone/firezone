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
    case device.latest_session do
      %{user_agent: ua} -> ua
      _ -> nil
    end
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
            :if={not is_nil(@client.verified_at)}
            name="ri-shield-check-line"
            class="h-2.5 w-2.5 text-neutral-500"
            title="Device attributes of this client are manually verified"
          />
        </div>
        <div>
          <.client_os_name_and_version client={@client} />
        </div>
        <div>
          <span>Last started:</span>
          <.relative_datetime
            datetime={@client.latest_session && @client.latest_session.timestamp}
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
      <.client_edit_header />
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

  def client_edit_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-border bg-elevated">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-heading">Edit Client</h2>
        <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="cancel_client_edit_form" />
      </div>
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
    <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-3 border-t border-border bg-elevated">
      <.button type="button" phx-click="cancel_client_edit_form" size="xs">
        Cancel
      </.button>
      <.button type="submit" style="primary" size="xs">
        Save
      </.button>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :client, :any, required: true
  attr :tab, :atom, default: :overview
  attr :confirm_delete_client, :boolean, default: false
  attr :confirm_unverify_client, :boolean, default: false
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
            <button
              role="tab"
              aria-selected={@tab == :overview}
              phx-click="switch_client_tab"
              phx-value-tab="overview"
              class={[
                "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
                if(@tab == :overview,
                  do: "border-brand text-brand",
                  else: "border-transparent text-body hover:text-heading"
                )
              ]}
            >
              Overview
            </button>
            <button
              role="tab"
              aria-selected={@tab == :authorizations}
              phx-click="switch_client_tab"
              phx-value-tab="authorizations"
              class={[
                "flex items-center gap-1.5 px-1 py-2.5 mr-5 text-xs font-medium border-b-2 transition-colors",
                if(@tab == :authorizations,
                  do: "border-brand text-brand",
                  else: "border-transparent text-body hover:text-heading"
                )
              ]}
            >
              Authorizations
            </button>
          </div>
          <div :if={@tab == :overview} class="flex-1 overflow-y-auto">
            <.client_owner_section account={@account} client={@client} />
            <.client_device_section client={@client} />
            <.client_network_section client={@client} />
          </div>
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
      <div
        :if={@policy_authorizations == []}
        class="flex flex-col items-center justify-center h-full gap-2 text-subtle"
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

  attr :client, :any, required: true

  def client_device_section(assigns) do
    ~H"""
    <div class="px-5 pt-4 pb-3 border-b border-border">
      <.section_heading title="Device" />
      <dl class="space-y-3">
        <.client_detail_row :if={@client.latest_session} label="Operating System">
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
        <.client_detail_row
          :if={@client.latest_session && @client.latest_session.remote_ip}
          label="Remote IP"
        >
          <span class="text-xs text-body">
            <.last_seen schema={@client.latest_session} />
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
        <.client_detail_row label="Verification">
          <.client_verified_status client={@client} />
        </.client_detail_row>
        <.client_detail_row label="Version">
          <.version
            current={@client.latest_session && @client.latest_session.version}
            latest={ComponentVersions.client_version(@client)}
          />
        </.client_detail_row>
        <.client_detail_row label="Last Seen">
          <span class="text-xs text-body">
            <.relative_datetime
              datetime={@client.latest_session && @client.latest_session.timestamp}
            />
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
    ~H"""
    <section>
      <.section_heading title="Actions" />
      <div class="space-y-1.5">
        <.action_button
          :if={is_nil(@client.verified_at)}
          icon="ri-shield-check-line"
          phx-click="verify_client"
        >
          Verify
        </.action_button>
        <.action_button
          :if={not is_nil(@client.verified_at) and not @confirm_unverify_client}
          icon="ri-prohibited-line"
          phx-click="confirm_unverify_client"
        >
          Revoke verification
        </.action_button>
        <div
          :if={not is_nil(@client.verified_at) and @confirm_unverify_client}
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
    ~H"""
    <span
      :if={not is_nil(@client.verified_at)}
      class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-success bg-success-light"
    >
      <.icon name="ri-shield-check-line" class="w-2.5 h-2.5" /> Verified
    </span>
    """
  end

  attr :client, :any, required: true

  def client_verified_status(assigns) do
    ~H"""
    <span
      :if={not is_nil(@client.verified_at)}
      class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-success bg-success-light"
    >
      <.icon name="ri-shield-check-line" class="w-2.5 h-2.5" /> Verified
    </span>
    <span
      :if={is_nil(@client.verified_at)}
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
  defp get_client_os_name_and_version(nil), do: ""

  defp get_client_os_name_and_version(user_agent) do
    String.split(user_agent, " ")
    |> Enum.reduce_while("", fn component, acc ->
      if String.contains?(component, "/") do
        {:halt, "#{acc} #{String.replace(component, "/", " ")}"}
      else
        {:cont, "#{acc} #{component}"}
      end
    end)
  end
end
