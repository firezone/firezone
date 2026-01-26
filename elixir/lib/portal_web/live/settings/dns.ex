defmodule PortalWeb.Settings.DNS do
  use PortalWeb, :live_view
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    account = Database.get_account_by_id!(socket.assigns.account.id, socket.assigns.subject)
    # Ensure config has proper defaults
    account = %{account | config: Portal.Accounts.Config.ensure_defaults(account.config)}

    socket =
      socket
      |> assign(page_title: "DNS")
      |> init(account)

    {:ok, socket}
  end

  defp init(socket, account) do
    changeset = change_account_config(account)

    assign(socket, form: to_form(changeset))
  end

  defp change_account_config(account, attrs \\ %{}) do
    import Ecto.Changeset

    account
    |> cast(attrs, [])
    |> cast_embed(:config)
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/dns"}>DNS Settings</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        DNS
      </:title>

      <:action>
        <.docs_action path="/deploy/dns" />
      </:action>

      <:help>
        <p>
          Configure the search domain and upstream resolvers used by devices when the Firezone Client is connected.
        </p>
      </:help>

      <:content>
        <div class="max-w-2xl px-4 py-8 mx-auto">
          <.form for={@form} phx-submit={:submit} phx-change={:change}>
            <h2 class="mb-4 text-xl text-neutral-900">Search Domain</h2>

            <p class="mb-4 text-neutral-500">
              The search domain, or default DNS suffix, will be appended to all single-label DNS queries made by Client devices
              while connected to Firezone.
            </p>

            <div class="mb-8">
              <.inputs_for :let={config_form} field={@form[:config]}>
                <.input
                  field={config_form[:search_domain]}
                  placeholder="E.g. example.com"
                  phx-debounce="300"
                />
                <p class="mt-2 text-sm text-neutral-500">
                  Enter a valid FQDN to append to single-label DNS queries. The
                  resulting FQDN will be used to match against DNS Resources in
                  your account, or forwarded to the upstream resolvers if no
                  match is found.
                </p>
              </.inputs_for>
            </div>

            <h2 class="mb-4 text-xl text-neutral-900">Upstream Resolvers</h2>

            <p class="mb-4 text-neutral-500">
              Queries for Resources will <strong>always</strong> use Firezone's internal DNS.
              All other queries will use the resolvers configured here.
            </p>

            <.inputs_for :let={config_form} field={@form[:config]}>
              <.inputs_for :let={dns_form} field={config_form[:clients_upstream_dns]}>
                <div class="mb-6">
                  <ul class="grid w-full gap-6 md:grid-cols-3">
                    <li>
                      <.input
                        id="dns-type--system"
                        type="radio_button_group"
                        field={dns_form[:type]}
                        value="system"
                        checked={"#{dns_form[:type].value}" == "system"}
                        required
                      />
                      <label for="dns-type--system" class={~w[
                        inline-flex items-center justify-between w-full
                        p-5 text-gray-500 bg-white border border-gray-200
                        rounded cursor-pointer peer-checked:border-accent-500
                        peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                      ]}>
                        <div class="block">
                          <div class="w-full font-semibold mb-3">
                            <.icon name="hero-computer-desktop" class="w-5 h-5 mr-1" /> System DNS
                          </div>
                          <div class="w-full text-sm">
                            Use the device's default DNS resolvers.
                          </div>
                        </div>
                      </label>
                    </li>
                    <li>
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
                          "inline-flex items-center justify-between w-full",
                          "p-5 text-gray-500 bg-white border border-gray-200",
                          "rounded cursor-pointer peer-checked:border-accent-500",
                          "peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100"
                        ]}
                      >
                        <div class="block">
                          <div class="w-full font-semibold mb-3">
                            <.icon name="hero-lock-closed" class="w-5 h-5 mr-1" /> Secure DNS
                          </div>
                          <div class="w-full text-sm">
                            Use DNS-over-HTTPS from trusted providers.
                          </div>
                        </div>
                      </label>
                    </li>
                    <li>
                      <.input
                        id="dns-type--custom"
                        type="radio_button_group"
                        field={dns_form[:type]}
                        value="custom"
                        checked={"#{dns_form[:type].value}" == "custom"}
                        required
                      />
                      <label for="dns-type--custom" class={~w[
                        inline-flex items-center justify-between w-full
                        p-5 text-gray-500 bg-white border border-gray-200
                        rounded cursor-pointer peer-checked:border-accent-500
                        peer-checked:text-accent-500 hover:text-gray-600 hover:bg-gray-100
                      ]}>
                        <div class="block">
                          <div class="w-full font-semibold mb-3">
                            <.icon name="hero-cog-6-tooth" class="w-5 h-5 mr-1" /> Custom DNS
                          </div>
                          <div class="w-full text-sm">
                            Configure your own DNS server addresses.
                          </div>
                        </div>
                      </label>
                    </li>
                  </ul>
                </div>

                <div :if={"#{dns_form[:type].value}" == "secure"} class="mb-6">
                  <label class="block mb-2 text-sm font-medium text-neutral-900">
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
                  <p class="mt-4 text-sm text-neutral-500">
                    <strong>Note:</strong>
                    Secure DNS is only supported on recent Clients. See the
                    <.website_link path="/kb/deploy/dns" fragment="secure-dns">
                      DNS configuration documentation
                    </.website_link>
                    for supported client versions.
                  </p>
                </div>

                <div
                  :if={"#{dns_form[:type].value}" == "custom"}
                  class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6"
                >
                  <div>
                    <p
                      :if={not Enum.empty?(dns_form[:addresses].value || [])}
                      class="mb-4 text-neutral-500"
                    >
                      Upstream resolvers will be used by Client devices in the order they are listed below.
                    </p>

                    <p
                      :if={Enum.empty?(dns_form[:addresses].value || [])}
                      class="mb-4 text-neutral-500"
                    >
                      No upstream resolvers have been configured. Click <strong>New Resolver</strong>
                      to add one.
                    </p>

                    <.inputs_for :let={address_form} field={dns_form[:addresses]}>
                      <input
                        type="hidden"
                        name="account[config][clients_upstream_dns][addresses_sort][]"
                        value={address_form.index}
                      />

                      <div class="flex gap-4 items-start mb-2">
                        <div class="flex-grow">
                          <.input
                            label="IP Address"
                            field={address_form[:address]}
                            placeholder="E.g. 1.1.1.1"
                            phx-debounce="300"
                          />
                        </div>
                        <div class="justify-self-end">
                          <div class="pt-7">
                            <button
                              type="button"
                              name="account[config][clients_upstream_dns][addresses_drop][]"
                              value={address_form.index}
                              phx-click={JS.dispatch("change")}
                            >
                              <.icon
                                name="hero-trash"
                                class="-ml-1 text-red-500 w-5 h-5 relative top-2"
                              />
                            </button>
                          </div>
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
                    <.button
                      class="mt-6 w-full"
                      type="button"
                      style="info"
                      name="account[config][clients_upstream_dns][addresses_sort][]"
                      value="new"
                      phx-click={JS.dispatch("change")}
                    >
                      New Resolver
                    </.button>

                    <p class="mt-4 text-sm text-neutral-500">
                      <strong>Note:</strong>
                      It is highly recommended to specify <strong>both</strong>
                      IPv4 and IPv6 addresses when adding upstream resolvers. Otherwise, Clients without IPv4
                      or IPv6 connectivity may not be able to resolve DNS queries.
                    </p>
                  </div>
                </div>
              </.inputs_for>
            </.inputs_for>

            <div class="mt-16">
              <.submit_button>
                Save DNS Settings
              </.submit_button>
            </div>
          </.form>
        </div>
      </:content>
    </.section>
    """
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
        socket =
          socket
          |> put_flash(:success, "DNS settings saved successfully")
          |> init(account)

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
    alias Portal.Account
    alias Portal.Authorization

    def get_account_by_id!(id, subject) do
      Authorization.with_subject(subject, fn ->
        from(a in Account, where: a.id == ^id)
        |> Portal.Repo.fetch!(:one)
      end)
    end

    def update(changeset, subject) do
      Authorization.with_subject(subject, fn ->
        Portal.Repo.update(changeset)
      end)
    end
  end
end
