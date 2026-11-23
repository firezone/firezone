defmodule PortalWeb.Settings.DNS do
  use PortalWeb, :live_view
  alias __MODULE__.Database
  alias PortalWeb.Settings

  def mount(_params, _session, socket) do
    # FetchAccount already loaded the account, so there is no need to query it again.
    account = socket.assigns.account
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
      <Page.page_header>
        <:title>DNS</:title>
        <:description>How devices resolve names that are not resources.</:description>
        <:action>
          <Navigation.docs_action show_label size="md" path="/deploy/dns" />
          <Form.button
            id="edit-dns-button"
            patch={~p"/#{@account}/settings/dns/edit"}
            icon="ri-pencil-line"
            size="sm"
          >
            Edit
          </Form.button>
        </:action>
      </Page.page_header>

      <div class="flex-1 overflow-auto px-6 pb-8">
        <Settings.Components.tiles cols="2" class="max-w-4xl">
          <Settings.Components.tile id="search-domain" label="Search domain" icon="ri-search-line">
            <%= if @dns_account.config.search_domain do %>
              <p class="text-sm font-semibold text-fg font-mono">
                {@dns_account.config.search_domain}
              </p>
            <% else %>
              <p class="text-sm text-muted">Not configured</p>
            <% end %>
            <p class="mt-1 text-xs text-muted">Appended to single-label queries.</p>
          </Settings.Components.tile>

          <.upstream_dns_display config={@dns_account.config} />
        </Settings.Components.tiles>
      </div>

      <Page.detail_modal
        id="edit-dns-panel"
        open={@live_action == :edit and assigns[:form] != nil}
        on_close="close_panel"
        size="md"
      >
        <Form.panel_header title="Edit DNS settings" variant="plain">
          <:leading><Core.icon name="ri-global-line" class="w-4 h-4 text-muted" /></:leading>
          <:adornment><Navigation.docs_action path="/deploy/dns" /></:adornment>
        </Form.panel_header>
        <Settings.Components.modal_body>
          <.dns_form form={@form} />
        </Settings.Components.modal_body>
        <Form.panel_footer>
          <Form.panel_footer_button phx-click="close_panel">
            Cancel
          </Form.panel_footer_button>
          <Form.panel_footer_button form="dns-form" type="submit" style="primary">
            Save
          </Form.panel_footer_button>
        </Form.panel_footer>
      </Page.detail_modal>
    </div>
    """
  end

  attr :config, :any, required: true

  defp upstream_dns_display(assigns) do
    dns = assigns.config.clients_upstream_dns

    {icon, label, description} =
      case dns && dns.type do
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
    <Settings.Components.tile id="upstream-dns" label="Upstream DNS" icon="ri-server-line">
      <div class="flex items-center gap-2">
        <Core.icon name={@icon} class="w-4 h-4 text-fg" />
        <span class="text-sm font-semibold text-fg">{@label}</span>
      </div>
      <p :if={@description} class="mt-1 text-xs text-muted">{@description}</p>
      <div
        :if={@dns && @dns.type == :custom && not Enum.empty?(@dns.addresses || [])}
        class="mt-2 flex flex-wrap gap-1.5"
      >
        <Core.badge :for={addr <- @dns.addresses} class="font-mono">
          {addr.address}
        </Core.badge>
      </div>
      <p
        :if={@dns && @dns.type == :custom && Enum.empty?(@dns.addresses || [])}
        class="mt-1 text-xs text-muted"
      >
        No resolvers configured.
      </p>
    </Settings.Components.tile>
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
          <h3 class="text-[11px] font-semibold uppercase tracking-[.12em] text-muted mb-4">
            Search domain
          </h3>
          <.inputs_for :let={config_form} field={@form[:config]}>
            <label
              for={config_form[:search_domain].id}
              class="block text-xs font-medium text-body mb-1.5"
            >
              Search domain
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
          <h3 class="text-[11px] font-semibold uppercase tracking-[.12em] text-muted mb-4">
            Upstream resolvers
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
                  DNS-over-HTTPS provider
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
                  No upstream resolvers configured. Click <strong>Add resolver</strong> to add one.
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
                      IP address
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
                  Add resolver
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
    alias Portal.Safe

    def update(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end
  end
end
