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
      class={["text-[var(--brand)] hover:underline", @class]}
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

  defp client_user_agent(client) do
    case client.latest_session do
      %{user_agent: ua} -> ua
      _ -> nil
    end
  end

  def client_os(assigns) do
    assigns = assign(assigns, :user_agent, client_user_agent(assigns.client))

    ~H"""
    <div class="flex items-center">
      <span class="mr-1 mb-1"><.client_os_icon client={@client} /></span>
      {get_client_os_name_and_version(@user_agent)}
    </div>
    """
  end

  def client_os_icon(assigns) do
    assigns = assign(assigns, :user_agent, client_user_agent(assigns.client))

    ~H"""
    <.icon
      name={client_os_icon_name(@user_agent)}
      title={get_client_os_name_and_version(@user_agent)}
      class="w-5 h-5"
    />
    """
  end

  def client_os_name_and_version(assigns) do
    assigns = assign(assigns, :user_agent, client_user_agent(assigns.client))

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
            datetime={@client.latest_session && @client.latest_session.inserted_at}
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
  def client_os_icon_name("Windows/" <> _), do: "os-windows"
  def client_os_icon_name("Mac OS/" <> _), do: "os-macos"
  def client_os_icon_name("iOS/" <> _), do: "os-ios"
  def client_os_icon_name("Android/" <> _), do: "os-android"
  def client_os_icon_name("Ubuntu/" <> _), do: "os-ubuntu"
  def client_os_icon_name("Debian/" <> _), do: "os-debian"
  def client_os_icon_name("Manjaro/" <> _), do: "os-manjaro"
  def client_os_icon_name("CentOS/" <> _), do: "os-linux"
  def client_os_icon_name("Fedora/" <> _), do: "os-linux"

  def client_os_icon_name(other) do
    if String.contains?(other, "linux") do
      "os-linux"
    else
      "os-other"
    end
  end

  @doc """
  Renders a version badge with the current version and icon based on whether the component is outdated.
  """
  attr :current, :string, required: true
  attr :latest, :string

  def version(%{current: nil} = assigns) do
    ~H"""
    <span class="text-xs text-[var(--text-muted)]">—</span>
    """
  end

  def version(assigns) do
    assigns =
      assign(assigns, outdated?: not is_nil(assigns.latest) and assigns.current != assigns.latest)

    ~H"""
    <.popover>
      <:target>
        <span class={[
          "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium font-mono",
          if(@outdated?,
            do: "text-[var(--status-warn)] bg-[var(--status-warn-bg)]",
            else: "text-[var(--status-active)] bg-[var(--status-active-bg)]"
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

  attr :account, :any, required: true
  attr :client, :any, required: true
  attr :panel, :map, required: true
  attr :confirm_state, :map, required: true
  attr :query_params, :map, default: %{}

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
        "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
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
          confirm_delete_client={@confirm_delete_client}
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
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-semibold text-[var(--text-primary)]">Edit Client</h2>
        <button
          phx-click="cancel_client_edit_form"
          class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
          title="Close (Esc)"
        >
          <.icon name="ri-close-line" class="w-4 h-4" />
        </button>
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
    """
  end

  def client_edit_actions(assigns) do
    ~H"""
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
    """
  end

  attr :account, :any, required: true
  attr :client, :any, required: true
  attr :confirm_delete_client, :boolean, default: false

  def client_details_view(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <.client_details_header client={@client} />
      <div class="flex flex-1 min-h-0 divide-x divide-[var(--border)]">
        <div class="flex-1 overflow-y-auto">
          <.client_owner_section account={@account} client={@client} />
          <.client_device_section client={@client} />
          <.client_network_section client={@client} />
        </div>
        <.client_sidebar client={@client} confirm_delete_client={@confirm_delete_client} />
      </div>
    </div>
    """
  end

  attr :client, :any, required: true

  def client_details_header(assigns) do
    ~H"""
    <div class="shrink-0 px-5 pt-4 pb-3 border-b border-[var(--border)] bg-[var(--surface-overlay)]">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <h2 class="text-sm font-semibold text-[var(--text-primary)]">{@client.name}</h2>
            <.client_verified_badge client={@client} />
          </div>
          <p class="font-mono text-xs text-[var(--text-tertiary)] mt-0.5">{@client.id}</p>
        </div>
        <div class="flex items-center gap-1.5 shrink-0">
          <button
            phx-click="open_client_edit_form"
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
      <.client_summary_bar client={@client} />
    </div>
    """
  end

  attr :client, :any, required: true

  def client_summary_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-5 mt-3 pt-3 border-t border-[var(--border)]">
      <div class="flex items-center gap-1.5">
        <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
          Status
        </span>
        <.status_badge status={if @client.online?, do: :online, else: :offline} />
      </div>
      <div class="w-px h-3.5 bg-[var(--border-strong)]"></div>
      <div class="flex items-center gap-1.5">
        <span class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
          Last Seen
        </span>
        <span class="text-xs text-[var(--text-secondary)]">
          <.relative_datetime datetime={@client.latest_session && @client.latest_session.inserted_at} />
        </span>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true
  attr :client, :any, required: true

  def client_owner_section(assigns) do
    ~H"""
    <div class="px-5 pt-4 pb-3 border-b border-[var(--border)]">
      <.section_heading title="Owner" />
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
    """
  end

  attr :client, :any, required: true

  def client_device_section(assigns) do
    ~H"""
    <div class="px-5 pt-4 pb-3 border-b border-[var(--border)]">
      <.section_heading title="Device" />
      <dl class="space-y-3">
        <.client_detail_row :if={@client.latest_session} label="Operating System">
          <.client_os client={@client} />
        </.client_detail_row>
        <.client_detail_row :if={@client.device_serial} label="Serial Number">
          <span class="font-mono text-sm text-[var(--text-primary)] font-medium">
            {@client.device_serial}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.device_uuid} label="Device UUID">
          <span class="font-mono text-xs text-[var(--text-secondary)] break-all">
            {@client.device_uuid}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.identifier_for_vendor} label="App Installation ID">
          <span class="font-mono text-xs text-[var(--text-secondary)] break-all">
            {@client.identifier_for_vendor}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.firebase_installation_id} label="App Installation ID">
          <span class="font-mono text-xs text-[var(--text-secondary)] break-all">
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
    <div :if={@client.ipv4 || @client.ipv6} class="px-5 pt-4 pb-3">
      <.section_heading title="Network" />
      <dl class="space-y-3">
        <.client_detail_row :if={@client.ipv4} label="Tunnel IPv4">
          <span class="font-mono text-xs text-[var(--text-secondary)]">
            {@client.ipv4}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.ipv6} label="Tunnel IPv6">
          <span class="font-mono text-xs text-[var(--text-secondary)] break-all">
            {@client.ipv6}
          </span>
        </.client_detail_row>
      </dl>
    </div>
    """
  end

  attr :client, :any, required: true
  attr :confirm_delete_client, :boolean, default: false

  def client_sidebar(assigns) do
    ~H"""
    <div class="w-1/3 shrink-0 overflow-y-auto p-4 space-y-5">
      <.client_details_card client={@client} />
      <div class="border-t border-[var(--border)]"></div>
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
          <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
            {@client.id}
          </span>
        </.client_detail_row>
        <.client_detail_row :if={@client.firezone_id} label="Firezone ID">
          <span class="font-mono text-[11px] text-[var(--text-secondary)] break-all">
            {@client.firezone_id}
          </span>
        </.client_detail_row>
        <.client_detail_row label="Verified">
          <.client_verified_status client={@client} />
        </.client_detail_row>
        <.client_detail_row label="Version">
          <.version
            current={@client.latest_session && @client.latest_session.version}
            latest={ComponentVersions.client_version(@client)}
          />
        </.client_detail_row>
        <.client_detail_row label="Created">
          <span class="text-xs text-[var(--text-secondary)]">
            <.relative_datetime datetime={@client.inserted_at} />
          </span>
        </.client_detail_row>
      </dl>
    </section>
    """
  end

  attr :confirm_delete_client, :boolean, default: false

  def client_danger_zone(assigns) do
    ~H"""
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
    """
  end

  attr :client, :any, required: true

  def client_verified_badge(assigns) do
    ~H"""
    <span
      :if={not is_nil(@client.verified_at)}
      class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-[var(--status-active)] bg-[var(--status-active-bg)]"
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
      class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-[var(--status-active)] bg-[var(--status-active-bg)]"
    >
      <.icon name="ri-shield-check-line" class="w-2.5 h-2.5" /> Verified
    </span>
    <span
      :if={is_nil(@client.verified_at)}
      class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium text-[var(--text-muted)] bg-[var(--surface-raised)]"
    >
      Unverified
    </span>
    """
  end

  attr :title, :string, required: true

  def section_heading(assigns) do
    ~H"""
    <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
      {@title}
    </h3>
    """
  end

  slot :inner_block, required: true
  attr :label, :string, required: true

  def client_detail_row(assigns) do
    ~H"""
    <div>
      <dt class="text-[10px] text-[var(--text-tertiary)] mb-0.5">{@label}</dt>
      <dd>{render_slot(@inner_block)}</dd>
    </div>
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
