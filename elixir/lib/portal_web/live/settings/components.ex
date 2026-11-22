defmodule PortalWeb.Settings.Components do
  use PortalWeb, :component_library

  @doc """
  Pulsing placeholder rows shown where data will appear once it has loaded.

  Pages render it on the static render instead of querying, so the data is
  only loaded once, by the connected mount.

  ## Examples

      <SettingsComponents.skeleton id="providers-skeleton" />
      <SettingsComponents.skeleton id="usage-skeleton" rows={3} class="max-w-2xl" />
  """
  attr :id, :string, required: true
  attr :rows, :integer, default: 4
  attr :class, :any, default: nil

  def skeleton(assigns) do
    ~H"""
    <div id={@id} aria-hidden="true" class={["animate-pulse", @class]}>
      <div
        :for={width <- Enum.take(Stream.cycle(~w[w-48 w-36 w-56 w-40]), @rows)}
        class="border-b border-border px-6 py-4"
      >
        <div class={["h-3 rounded bg-border-strong max-w-full", width]}></div>
        <div class="mt-2 h-2 w-24 rounded bg-border"></div>
      </div>
    </div>
    """
  end

  @doc """
  The search domain and upstream resolver inputs for a `Portal.Accounts.Config`
  embed, shared by the account DNS settings and a device's own DNS settings.
  """
  attr :field, Phoenix.HTML.FormField, required: true

  def dns_config_fields(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <h3 class="text-[10px] font-semibold uppercase tracking-widest text-subtle mb-4">
          Search Domain
        </h3>
        <.inputs_for :let={config_form} field={@field}>
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
        <.inputs_for :let={config_form} field={@field}>
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
                  name={dns_form.name <> "[addresses_sort][]"}
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
                      name={dns_form.name <> "[addresses_drop][]"}
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
                name={dns_form.name <> "[addresses_drop][]"}
              />

              <Form.button
                :if={Enum.count(dns_form[:addresses].value || []) < 8}
                type="button"
                name={dns_form.name <> "[addresses_sort][]"}
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
    </div>
    """
  end

  @doc "A `Portal.Accounts.Config` DNS setting in one plain line."
  def dns_config_summary(config) do
    config = Portal.Accounts.Config.ensure_defaults(config)
    search_domain = config.search_domain || "none"
    "#{upstream_dns_summary(config.clients_upstream_dns)}, search domain #{search_domain}"
  end

  def doh_provider_label(:google), do: "Google Public DNS"
  def doh_provider_label(:cloudflare), do: "Cloudflare DNS"
  def doh_provider_label(:quad9), do: "Quad9 DNS"
  def doh_provider_label(:opendns), do: "OpenDNS"
  def doh_provider_label(_), do: "Unknown"

  defp upstream_dns_summary(%Portal.UpstreamDNS{type: :secure, doh_provider: provider}),
    do: "DNS over HTTPS with #{doh_provider_label(provider)}"

  defp upstream_dns_summary(%Portal.UpstreamDNS{type: :custom, addresses: [_ | _] = addresses}),
    do: "custom resolvers #{Enum.map_join(addresses, ", ", & &1.address)}"

  defp upstream_dns_summary(_dns), do: "each device's own resolvers"
end
