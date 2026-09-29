defmodule PortalWeb.Settings.Connectivity do
  use PortalWeb, :live_view
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    account = Database.get_account_by_id!(socket.assigns.account.id, socket.assigns.subject)
    account = %{account | config: Portal.Accounts.Config.ensure_defaults(account.config)}

    socket =
      socket
      |> assign(page_title: "Connectivity")
      |> assign(connectivity_account: account)
      |> assign(aes_gcm_available: Portal.Features.enabled?(:aes_gcm))

    {:ok, socket}
  end

  def handle_params(_params, _url, %{assigns: %{live_action: :edit}} = socket) do
    changeset =
      change_account_config(
        socket.assigns.connectivity_account,
        %{},
        socket.assigns.aes_gcm_available
      )

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp change_account_config(account, attrs, aes_gcm_available) do
    import Ecto.Changeset

    changeset =
      account
      |> cast(attrs, [])
      |> cast_embed(:config)

    case get_change(changeset, :config) do
      %Ecto.Changeset{changes: %{aes_gcm: _}} when not aes_gcm_available ->
        add_error(changeset, :config, "Tunnel encryption settings are not available")

      _ ->
        changeset
    end
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <Navigation.settings_nav
        account={@account}
        current_path={@current_path}
      />

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex items-center justify-between px-6 py-3 border-b border-border shrink-0">
          <h2 class="text-xs font-semibold text-heading">Connectivity</h2>
          <div class="flex items-center gap-2">
            <Navigation.link
              patch={~p"/#{@account}/settings/connectivity/edit"}
              class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
            >
              <Core.icon name="ri-pencil-line" class="w-3 h-3" /> Edit
            </Navigation.link>
          </div>
        </div>

        <div class="flex-1 overflow-auto p-6 space-y-8">
          <div class="max-w-sm space-y-3">
            <div class="flex items-center justify-between">
              <h3 class="text-[10px] font-semibold uppercase tracking-widest text-subtle">DNS</h3>
              <Navigation.docs_action path="/deploy/dns" />
            </div>
            <div class="rounded border border-border bg-surface px-4 py-3">
              <p class="text-[10px] font-semibold uppercase tracking-widest text-subtle mb-1">
                Search Domain
              </p>
              <%= if @connectivity_account.config.search_domain do %>
                <p class="text-sm font-semibold text-heading font-mono">
                  {@connectivity_account.config.search_domain}
                </p>
              <% else %>
                <p class="text-sm text-subtle italic">Not configured</p>
              <% end %>
            </div>

            <.upstream_dns_display config={@connectivity_account.config} />
          </div>

          <div :if={@aes_gcm_available} id="tunnel-encryption" class="max-w-sm space-y-3">
            <h3 class="text-[10px] font-semibold uppercase tracking-widest text-subtle">
              Tunnel Encryption
            </h3>
            <div class="rounded border border-border bg-surface px-4 py-3">
              <p class="text-[10px] font-semibold uppercase tracking-widest text-subtle mb-1">
                AES-256-GCM
              </p>
              <p class="text-sm font-semibold text-heading">
                {if @connectivity_account.config.aes_gcm, do: "Used when supported", else: "Disabled"}
              </p>
              <p class="mt-1 text-xs text-subtle">{aes_gcm_description()}</p>
            </div>
          </div>
        </div>
      </div>

    <!-- Edit Panel -->
      <div
        id="edit-connectivity-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-elevated border-l border-border-strong",
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
          <Form.panel_header title="Edit Connectivity Settings" variant="plain">
            <:adornment><Navigation.docs_action path="/deploy/dns" /></:adornment>
          </Form.panel_header>
          <div class="flex-1 overflow-y-auto px-5 py-4">
            <.connectivity_form form={@form} aes_gcm_available={@aes_gcm_available} />
          </div>
          <Form.panel_footer>
            <Form.panel_footer_button phx-click="close_panel">
              Cancel
            </Form.panel_footer_button>
            <Form.panel_footer_button form="connectivity-form" type="submit" style="primary">
              Save
            </Form.panel_footer_button>
          </Form.panel_footer>
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
          provider = doh_provider_label(dns.doh_provider)
          {"ri-lock-line", "Secure DNS", "DNS-over-HTTPS via #{provider}."}

        :custom ->
          {"ri-settings-3-line", "Custom DNS", nil}

        _ ->
          {"ri-computer-line", "System DNS", "Use the device's default DNS resolvers."}
      end

    assigns = assign(assigns, icon: icon, label: label, description: description, dns: dns)

    ~H"""
    <div class="rounded border border-border bg-surface px-4 py-3">
      <p class="text-[10px] font-semibold uppercase tracking-widest text-subtle mb-1.5">
        Upstream DNS
      </p>
      <div class="flex items-center gap-2">
        <Core.icon name={@icon} class="w-4 h-4 text-brand" />
        <span class="text-sm font-semibold text-heading">{@label}</span>
      </div>
      <p :if={@description} class="mt-1 text-xs text-subtle">{@description}</p>
      <div
        :if={@dns && @dns.type == :custom && not Enum.empty?(@dns.addresses || [])}
        class="mt-2 flex flex-wrap gap-1.5"
      >
        <span
          :for={addr <- @dns.addresses}
          class="text-xs font-mono px-1.5 py-0.5 rounded bg-raised text-body"
        >
          {addr.address}
        </span>
      </div>
      <p
        :if={@dns && @dns.type == :custom && Enum.empty?(@dns.addresses || [])}
        class="mt-1 text-xs text-subtle italic"
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

  defp aes_gcm_description do
    "Clients and Gateways with hardware AES support use the Noise_IKpsk2_25519_AESGCM_BLAKE2s " <>
      "protocol for higher throughput. Connections fall back to standard WireGuard otherwise."
  end

  attr :form, :any, required: true
  attr :aes_gcm_available, :boolean, required: true

  defp connectivity_form(assigns) do
    ~H"""
    <.form id="connectivity-form" for={@form} phx-submit={:submit} phx-change={:change}>
      <Core.error :for={{msg, _opts} <- @form[:config].errors}>{msg}</Core.error>
      <div class="space-y-8">
        <div>
          <h3 class="text-[10px] font-semibold uppercase tracking-widest text-subtle mb-4">
            Search Domain
          </h3>
          <.inputs_for :let={config_form} field={@form[:config]}>
            <label
              for={config_form[:search_domain].id}
              class="block text-xs font-medium text-body mb-1.5"
            >
              Search Domain
            </label>
            <Form.input
              field={config_form[:search_domain]}
              placeholder="E.g. example.com"
              phx-debounce="300"
            />
            <p class="mt-1.5 text-xs text-subtle">
              Enter a valid FQDN to append to single-label DNS queries. The resulting FQDN will be
              used to match against DNS Resources in your account, or forwarded to the upstream
              resolvers if no match is found.
            </p>
          </.inputs_for>
        </div>

        <div>
          <h3 class="text-[10px] font-semibold uppercase tracking-widest text-subtle mb-4">
            Upstream Resolvers
          </h3>
          <p class="mb-4 text-xs text-body">
            Queries for Resources will <strong>always</strong>
            use Firezone's internal DNS. All other queries will use the resolvers configured here.
          </p>
          <.inputs_for :let={config_form} field={@form[:config]}>
            <.inputs_for :let={dns_form} field={config_form[:clients_upstream_dns]}>
              <div class="grid gap-3 grid-cols-3 mb-6">
                <div>
                  <Form.input
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
                      "flex flex-col h-full p-3 border rounded cursor-pointer transition-all",
                      "peer-checked:border-brand peer-checked:bg-raised",
                      "border-border hover:border-border-emphasis"
                    ]}
                  >
                    <span class="text-sm font-semibold text-heading mb-1 flex items-center gap-1.5">
                      <Core.icon name="ri-computer-line" class="w-4 h-4 shrink-0" /> System
                    </span>
                    <span class="text-xs text-body my-auto">
                      Use the device's default DNS resolvers.
                    </span>
                  </label>
                </div>

                <div>
                  <Form.input
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
                      "flex flex-col h-full p-3 border rounded cursor-pointer transition-all",
                      "peer-checked:border-brand peer-checked:bg-raised",
                      "border-border hover:border-border-emphasis"
                    ]}
                  >
                    <span class="text-sm font-semibold text-heading mb-1 flex items-center gap-1.5">
                      <Core.icon name="ri-lock-line" class="w-4 h-4 shrink-0" /> Secure
                    </span>
                    <span class="text-xs text-body my-auto">
                      Use DNS-over-HTTPS from trusted providers.
                    </span>
                  </label>
                </div>

                <div>
                  <Form.input
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
                      "flex flex-col h-full p-3 border rounded cursor-pointer transition-all",
                      "peer-checked:border-brand peer-checked:bg-raised",
                      "border-border hover:border-border-emphasis"
                    ]}
                  >
                    <span class="text-sm font-semibold text-heading mb-1 flex items-center gap-1.5">
                      <Core.icon name="ri-settings-3-line" class="w-4 h-4 shrink-0" /> Custom
                    </span>
                    <span class="text-xs text-body my-auto">
                      Configure your own DNS server addresses.
                    </span>
                  </label>
                </div>
              </div>

              <div :if={"#{dns_form[:type].value}" == "secure"} class="space-y-3">
                <label
                  for={dns_form[:doh_provider].id}
                  class="block text-xs font-medium text-body mb-1.5"
                >
                  DNS-over-HTTPS Provider
                </label>
                <Form.input
                  type="select"
                  field={dns_form[:doh_provider]}
                  options={[
                    {"Google Public DNS", :google},
                    {"Cloudflare DNS", :cloudflare},
                    {"Quad9 DNS", :quad9},
                    {"OpenDNS", :opendns}
                  ]}
                />
                <p class="mt-1.5 text-xs text-subtle">
                  Secure DNS is only supported on recent Clients. See the
                  <Navigation.website_link path="/kb/deploy/dns" fragment="secure-dns">
                    DNS configuration documentation
                  </Navigation.website_link>
                  for supported client versions.
                </p>
              </div>

              <div :if={"#{dns_form[:type].value}" == "custom"} class="space-y-4">
                <p
                  :if={not Enum.empty?(dns_form[:addresses].value || [])}
                  class="text-xs text-body"
                >
                  Upstream resolvers will be used by devices when the Firezone Client is signed in, in the order listed below.
                </p>
                <p
                  :if={Enum.empty?(dns_form[:addresses].value || [])}
                  class="text-xs text-body"
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
                      class="block text-xs font-medium text-body mb-1.5"
                    >
                      IP Address
                    </label>
                    <div class="flex gap-2 items-start">
                      <div class="flex-1">
                        <Form.input
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
                        class="flex items-center justify-center w-9 h-9 rounded text-error hover:bg-raised transition-colors shrink-0"
                      >
                        <Core.icon name="ri-delete-bin-line" class="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                </.inputs_for>

                <Core.error :for={{msg, _opts} <- dns_form[:addresses].errors}>
                  {msg}
                </Core.error>

                <input
                  type="hidden"
                  name="account[config][clients_upstream_dns][addresses_drop][]"
                />

                <Form.button
                  :if={Enum.count(dns_form[:addresses].value || []) < 8}
                  type="button"
                  name="account[config][clients_upstream_dns][addresses_sort][]"
                  value="new"
                  phx-click={JS.dispatch("change")}
                  size="xs"
                  icon="ri-add-line"
                >
                  Add Resolver
                </Form.button>
                <p
                  :if={Enum.count(dns_form[:addresses].value || []) >= 8}
                  class="text-xs text-subtle"
                >
                  Maximum of 8 upstream resolvers reached.
                </p>

                <p class="text-xs text-subtle">
                  <strong>Note:</strong>
                  It is highly recommended to specify <strong>both</strong>
                  IPv4 and IPv6 addresses when adding upstream resolvers. Otherwise, Clients without
                  IPv4 or IPv6 connectivity may not be able to resolve DNS queries.
                </p>
              </div>
            </.inputs_for>
          </.inputs_for>
        </div>

        <div :if={@aes_gcm_available}>
          <h3 class="text-[10px] font-semibold uppercase tracking-widest text-subtle mb-4">
            Tunnel Encryption
          </h3>
          <.inputs_for :let={config_form} field={@form[:config]}>
            <div class="flex items-start justify-between gap-6">
              <div class="min-w-0">
                <label for={config_form[:aes_gcm].id} class="block text-xs font-medium text-body">
                  Use AES-256-GCM when supported
                </label>
                <p class="mt-1.5 text-xs text-subtle">{aes_gcm_description()}</p>
              </div>
              <input type="hidden" name={config_form[:aes_gcm].name} value="false" />
              <Core.toggle
                id={config_form[:aes_gcm].id}
                name={config_form[:aes_gcm].name}
                value="true"
                checked={Phoenix.HTML.Form.normalize_value("checkbox", config_form[:aes_gcm].value)}
              />
            </div>
          </.inputs_for>
        </div>
      </div>
    </.form>
    """
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/connectivity")}
  end

  def handle_event(
        "handle_keydown",
        %{"key" => "Escape"},
        %{assigns: %{live_action: :edit}} = socket
      ) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/connectivity")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("change", %{"account" => params}, socket) do
    form =
      socket.assigns.form.data
      |> change_account_config(params, socket.assigns.aes_gcm_available)
      |> to_form(action: :validate)

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", %{"account" => params}, socket) do
    aes_gcm_available = Portal.Features.enabled?(:aes_gcm)
    socket = assign(socket, aes_gcm_available: aes_gcm_available)

    case update_account_config(
           socket.assigns.form.data,
           params,
           aes_gcm_available,
           socket.assigns.subject
         ) do
      {:ok, account} ->
        account = %{account | config: Portal.Accounts.Config.ensure_defaults(account.config)}

        socket =
          socket
          |> put_flash(:success, "Connectivity settings saved successfully")
          |> assign(connectivity_account: account)
          |> push_patch(to: ~p"/#{socket.assigns.account}/settings/connectivity")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_account_config(account, attrs, aes_gcm_available, subject) do
    account
    |> change_account_config(attrs, aes_gcm_available)
    |> Database.update(subject)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account

    def get_account_by_id!(id, subject) do
      from(a in Account, where: a.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def update(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end
  end
end
