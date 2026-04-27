defmodule PortalWeb.Settings.DNS do
  use PortalWeb, :live_view
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    account = Database.get_account_by_id!(socket.assigns.account.id, socket.assigns.subject)
    account = %{account | config: Portal.Accounts.Config.ensure_defaults(account.config)}

    socket =
      socket
      |> assign(page_title: "DNS")
      |> assign(dns_account: account)

    {:ok, socket}
  end

  def handle_params(_params, _url, %{assigns: %{live_action: :edit}} = socket) do
    changeset = change_account_config(socket.assigns.dns_account)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp change_account_config(account, attrs \\ %{}) do
    import Ecto.Changeset

    account
    |> cast(attrs, [])
    |> cast_embed(:config)
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.settings_nav account={@account} current_path={@current_path} />

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex items-center justify-between px-6 py-3 border-b border-[var(--border)] shrink-0">
          <h2 class="text-xs font-semibold text-[var(--text-primary)]">DNS Configuration</h2>
          <div class="flex items-center gap-2">
            <.docs_action path="/deploy/dns" />
            <.link
              patch={~p"/#{@account}/settings/dns/edit"}
              class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              <.icon name="ri-pencil-line" class="w-3 h-3" /> Edit
            </.link>
          </div>
        </div>

        <div class="flex-1 overflow-auto p-6">
          <div class="max-w-sm space-y-3">
            <div class="rounded border border-[var(--border)] bg-[var(--surface)] px-4 py-3">
              <p class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-tertiary)] mb-1">
                Search Domain
              </p>
              <%= if @dns_account.config.search_domain do %>
                <p class="text-sm font-semibold text-[var(--text-primary)] font-mono">
                  {@dns_account.config.search_domain}
                </p>
              <% else %>
                <p class="text-sm text-[var(--text-tertiary)] italic">Not configured</p>
              <% end %>
            </div>

            <.upstream_dns_display config={@dns_account.config} />
          </div>
        </div>
      </div>

    <!-- Edit Panel -->
      <div
        id="edit-dns-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-[var(--surface-overlay)] border-l border-[var(--border-strong)]",
          "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
          "transition-transform duration-200 ease-in-out",
          (@live_action == :edit && assigns[:form] != nil && "translate-x-0") || "translate-x-full"
        ]}
        phx-window-keydown="handle_keydown"
        phx-key="Escape"
      >
        <div
          :if={@live_action == :edit and assigns[:form] != nil}
          class="flex flex-col h-full overflow-hidden"
        >
          <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-[var(--border)]">
            <div class="flex items-center gap-2">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">Edit DNS Settings</h2>
              <.docs_action path="/deploy/dns" />
            </div>
            <button
              phx-click="close_panel"
              class="flex items-center justify-center w-7 h-7 rounded text-[var(--text-tertiary)] hover:text-[var(--text-primary)] hover:bg-[var(--surface-raised)] transition-colors"
              title="Close (Esc)"
            >
              <.icon name="ri-close-line" class="w-4 h-4" />
            </button>
          </div>
          <div class="flex-1 overflow-y-auto px-5 py-4">
            <.dns_form form={@form} />
          </div>
          <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-4 border-t border-[var(--border)]">
            <button
              phx-click="close_panel"
              class="px-3 py-1.5 text-sm rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Cancel
            </button>
            <button
              form="dns-form"
              type="submit"
              class="px-3 py-1.5 text-sm rounded bg-[var(--brand)] text-white hover:bg-[var(--brand-hover)] transition-colors"
            >
              Save
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :config, :any, required: true

  defp upstream_dns_display(assigns) do
    dns = assigns.config.clients_upstream_dns

    {icon, label, description} =
      case dns && dns.type do
        :system ->
          {"ri-computer-line", "System DNS", "Use the device's default DNS resolvers."}

        :secure ->
          provider = doh_provider_label(dns && dns.doh_provider)
          {"ri-lock-line", "Secure DNS", "DNS-over-HTTPS via #{provider}."}

        :custom ->
          {"ri-settings-3-line", "Custom DNS", nil}

        _ ->
          {"ri-computer-line", "System DNS", "Use the device's default DNS resolvers."}
      end

    assigns = assign(assigns, icon: icon, label: label, description: description, dns: dns)

    ~H"""
    <div class="rounded border border-[var(--border)] bg-[var(--surface)] px-4 py-3">
      <p class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-tertiary)] mb-1.5">
        Upstream DNS
      </p>
      <div class="flex items-center gap-2">
        <.icon name={@icon} class="w-4 h-4 text-[var(--brand)]" />
        <span class="text-sm font-semibold text-[var(--text-primary)]">{@label}</span>
      </div>
      <p :if={@description} class="mt-1 text-xs text-[var(--text-tertiary)]">{@description}</p>
      <div
        :if={@dns && @dns.type == :custom && not Enum.empty?(@dns.addresses || [])}
        class="mt-2 flex flex-wrap gap-1.5"
      >
        <span
          :for={addr <- @dns.addresses}
          class="text-xs font-mono px-1.5 py-0.5 rounded bg-[var(--surface-raised)] text-[var(--text-secondary)]"
        >
          {addr.address}
        </span>
      </div>
      <p
        :if={@dns && @dns.type == :custom && Enum.empty?(@dns.addresses || [])}
        class="mt-1 text-xs text-[var(--text-tertiary)] italic"
      >
        No resolvers configured.
      </p>
    </div>
    """
  end

  defp doh_provider_label(:google), do: "Google Public DNS"
  defp doh_provider_label(:cloudflare), do: "Cloudflare DNS"
  defp doh_provider_label(:quad9), do: "Quad9 DNS"
  defp doh_provider_label(:opendns), do: "OpenDNS"
  defp doh_provider_label(_), do: "Unknown"

  attr :form, :any, required: true

  defp dns_form(assigns) do
    ~H"""
    <.form id="dns-form" for={@form} phx-submit={:submit} phx-change={:change}>
      <div class="space-y-8">
        <div>
          <h3 class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-tertiary)] mb-4">
            Search Domain
          </h3>
          <.inputs_for :let={config_form} field={@form[:config]}>
            <label
              for={config_form[:search_domain].id}
              class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
            >
              Search Domain
            </label>
            <.input
              field={config_form[:search_domain]}
              placeholder="E.g. example.com"
              phx-debounce="300"
            />
            <p class="mt-1.5 text-xs text-[var(--text-tertiary)]">
              Enter a valid FQDN to append to single-label DNS queries. The resulting FQDN will be
              used to match against DNS Resources in your account, or forwarded to the upstream
              resolvers if no match is found.
            </p>
          </.inputs_for>
        </div>

        <div>
          <h3 class="text-[10px] font-semibold uppercase tracking-widest text-[var(--text-tertiary)] mb-4">
            Upstream Resolvers
          </h3>
          <p class="mb-4 text-xs text-[var(--text-secondary)]">
            Queries for Resources will <strong>always</strong>
            use Firezone's internal DNS. All other queries will use the resolvers configured here.
          </p>
          <.inputs_for :let={config_form} field={@form[:config]}>
            <.inputs_for :let={dns_form} field={config_form[:clients_upstream_dns]}>
              <div class="grid gap-3 grid-cols-3 mb-6">
                <div>
                  <.input
                    id="dns-type--system"
                    type="radio_button_group"
                    field={dns_form[:type]}
                    value="system"
                    checked={"#{dns_form[:type].value}" == "system"}
                    required
                  />
                  <label
                    for="dns-type--system"
                    class={[
                      "flex flex-col p-3 border rounded cursor-pointer transition-all",
                      "peer-checked:border-[var(--brand)] peer-checked:bg-[var(--surface-raised)]",
                      "border-[var(--border)] hover:border-[var(--border-emphasis)]"
                    ]}
                  >
                    <span class="text-sm font-semibold text-[var(--text-primary)] mb-1 flex items-center gap-1.5">
                      <.icon name="ri-computer-line" class="w-4 h-4 shrink-0" /> System
                    </span>
                    <span class="text-xs text-[var(--text-secondary)]">
                      Use the device's default DNS resolvers.
                    </span>
                  </label>
                </div>

                <div>
                  <.input
                    id="dns-type--secure"
                    type="radio_button_group"
                    field={dns_form[:type]}
                    value="secure"
                    checked={"#{dns_form[:type].value}" == "secure"}
                    required
                  />
                  <label
                    for="dns-type--secure"
                    class={[
                      "flex flex-col p-3 border rounded cursor-pointer transition-all",
                      "peer-checked:border-[var(--brand)] peer-checked:bg-[var(--surface-raised)]",
                      "border-[var(--border)] hover:border-[var(--border-emphasis)]"
                    ]}
                  >
                    <span class="text-sm font-semibold text-[var(--text-primary)] mb-1 flex items-center gap-1.5">
                      <.icon name="ri-lock-line" class="w-4 h-4 shrink-0" /> Secure
                    </span>
                    <span class="text-xs text-[var(--text-secondary)]">
                      Use DNS-over-HTTPS from trusted providers.
                    </span>
                  </label>
                </div>

                <div>
                  <.input
                    id="dns-type--custom"
                    type="radio_button_group"
                    field={dns_form[:type]}
                    value="custom"
                    checked={"#{dns_form[:type].value}" == "custom"}
                    required
                  />
                  <label
                    for="dns-type--custom"
                    class={[
                      "flex flex-col p-3 border rounded cursor-pointer transition-all",
                      "peer-checked:border-[var(--brand)] peer-checked:bg-[var(--surface-raised)]",
                      "border-[var(--border)] hover:border-[var(--border-emphasis)]"
                    ]}
                  >
                    <span class="text-sm font-semibold text-[var(--text-primary)] mb-1 flex items-center gap-1.5">
                      <.icon name="ri-settings-3-line" class="w-4 h-4 shrink-0" /> Custom
                    </span>
                    <span class="text-xs text-[var(--text-secondary)]">
                      Configure your own DNS server addresses.
                    </span>
                  </label>
                </div>
              </div>

              <div :if={"#{dns_form[:type].value}" == "secure"} class="space-y-3">
                <label
                  for={dns_form[:doh_provider].id}
                  class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
                >
                  DNS-over-HTTPS Provider
                </label>
                <.input
                  type="select"
                  field={dns_form[:doh_provider]}
                  options={[
                    {"Google Public DNS", :google},
                    {"Cloudflare DNS", :cloudflare},
                    {"Quad9 DNS", :quad9},
                    {"OpenDNS", :opendns}
                  ]}
                />
                <p class="mt-1.5 text-xs text-[var(--text-tertiary)]">
                  Secure DNS is only supported on recent Clients. See the
                  <.website_link path="/kb/deploy/dns" fragment="secure-dns">
                    DNS configuration documentation
                  </.website_link>
                  for supported client versions.
                </p>
              </div>

              <div :if={"#{dns_form[:type].value}" == "custom"} class="space-y-4">
                <p
                  :if={not Enum.empty?(dns_form[:addresses].value || [])}
                  class="text-xs text-[var(--text-secondary)]"
                >
                  Upstream resolvers will be used by Client devices in the order listed below.
                </p>
                <p
                  :if={Enum.empty?(dns_form[:addresses].value || [])}
                  class="text-xs text-[var(--text-secondary)]"
                >
                  No upstream resolvers configured. Click <strong>Add Resolver</strong> to add one.
                </p>

                <.inputs_for :let={address_form} field={dns_form[:addresses]}>
                  <input
                    type="hidden"
                    name="account[config][clients_upstream_dns][addresses_sort][]"
                    value={address_form.index}
                  />
                  <div>
                    <label
                      for={address_form[:address].id}
                      class="block text-xs font-medium text-[var(--text-secondary)] mb-1.5"
                    >
                      IP Address
                    </label>
                    <div class="flex gap-2 items-start">
                      <div class="flex-1">
                        <.input
                          field={address_form[:address]}
                          placeholder="E.g. 1.1.1.1"
                          phx-debounce="300"
                        />
                      </div>
                      <button
                        type="button"
                        name="account[config][clients_upstream_dns][addresses_drop][]"
                        value={address_form.index}
                        phx-click={JS.dispatch("change")}
                        class="flex items-center justify-center w-9 h-9 rounded text-[var(--status-error)] hover:bg-[var(--surface-raised)] transition-colors shrink-0"
                      >
                        <.icon name="ri-delete-bin-line" class="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                </.inputs_for>

                <.error :for={{msg, _opts} <- dns_form[:addresses].errors}>
                  {msg}
                </.error>

                <input
                  type="hidden"
                  name="account[config][clients_upstream_dns][addresses_drop][]"
                />

                <button
                  type="button"
                  name="account[config][clients_upstream_dns][addresses_sort][]"
                  value="new"
                  phx-click={JS.dispatch("change")}
                  class="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
                >
                  <.icon name="ri-add-line" class="w-3.5 h-3.5" /> Add Resolver
                </button>

                <p class="text-xs text-[var(--text-tertiary)]">
                  <strong>Note:</strong>
                  It is highly recommended to specify <strong>both</strong>
                  IPv4 and IPv6 addresses when adding upstream resolvers. Otherwise, Clients without
                  IPv4 or IPv6 connectivity may not be able to resolve DNS queries.
                </p>
              </div>
            </.inputs_for>
          </.inputs_for>
        </div>
      </div>
    </.form>
    """
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/dns")}
  end

  def handle_event(
        "handle_keydown",
        %{"key" => "Escape"},
        %{assigns: %{live_action: :edit}} = socket
      ) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/dns")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("change", %{"account" => params}, socket) do
    form =
      socket.assigns.form.data
      |> change_account_config(params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", %{"account" => params}, socket) do
    case update_account_config(socket.assigns.form.data, params, socket.assigns.subject) do
      {:ok, account} ->
        account = %{account | config: Portal.Accounts.Config.ensure_defaults(account.config)}

        socket =
          socket
          |> put_flash(:success, "DNS settings saved successfully")
          |> assign(dns_account: account)
          |> push_patch(to: ~p"/#{socket.assigns.account}/settings/dns")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_account_config(account, attrs, subject) do
    account
    |> change_account_config(attrs)
    |> Database.update(subject)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def get_account_by_id!(id, subject) do
      from(a in Account, where: a.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def update(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end
  end
end
