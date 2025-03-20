defmodule Web.Settings.DNS do
  use Web, :live_view
  alias Domain.Accounts

  def mount(_params, _session, socket) do
    with {:ok, account} <-
           Accounts.fetch_account_by_id(socket.assigns.account.id, socket.assigns.subject) do
      form =
        Accounts.change_account(account, %{})
        |> to_form()

      socket =
        assign(socket,
          page_title: "DNS",
          account: account,
          form: form
        )

      {:ok, socket}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
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
            <.flash kind={:success} flash={@flash} phx-click="lv:clear-flash" />

            <.inputs_for :let={config} field={@form[:config]}>
              <h2 class="mb-4 text-xl text-neutral-900">Search Domain</h2>

              <p class="mb-4 text-neutral-500">
                The search domain, or default DNS suffix, will be appended to all single-label DNS queries made by Client devices
                while connected to Firezone.
              </p>

              <div class="mb-8">
                <.input field={config[:search_domain]} placeholder="E.g. example.com" />
                <p class="mt-2 text-sm text-neutral-500">
                  Enter a valid FQDN to append to single-label DNS queries. The
                  resulting FQDN will be used to match against DNS Resources in
                  your account, or forwarded to the upstream resolvers if no
                  match is found.
                </p>
              </div>

              <h2 class="mb-4 text-xl text-neutral-900">Upstream Resolvers</h2>

              <p class="mb-4 text-neutral-500">
                Queries for Resources will <strong>always</strong> use Firezone's internal DNS.
                All other queries will use the resolvers configured here or the device's
                system resolvers if none are configured.
              </p>

              <p :if={not upstream_dns_empty?(@account, @form)} class="mb-4 text-neutral-500">
                Upstream resolvers will be used by Client devices in the order they are listed below.
              </p>

              <p :if={upstream_dns_empty?(@account, @form)} class="text-neutral-500">
                No upstream resolvers have been configured. Click <strong>New Resolver</strong>
                to add one.
              </p>

              <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
                <div>
                  <.inputs_for :let={dns} field={config[:clients_upstream_dns]}>
                    <input
                      type="hidden"
                      name={"#{config.name}[clients_upstream_dns_sort][]"}
                      value={dns.index}
                    />

                    <div class="flex gap-4 items-start mb-2">
                      <div class="w-3/12">
                        <.input
                          type="select"
                          label="Protocol"
                          field={dns[:protocol]}
                          placeholder="Protocol"
                          options={dns_options()}
                          value={dns[:protocol].value}
                        />
                      </div>
                      <div class="flex-grow">
                        <.input label="Address" field={dns[:address]} placeholder="E.g. 1.1.1.1" />
                      </div>
                      <div class="justify-self-end">
                        <div class="pt-7">
                          <button
                            type="button"
                            name={"#{config.name}[clients_upstream_dns_drop][]"}
                            value={dns.index}
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

                  <input type="hidden" name={"#{config.name}[clients_upstream_dns_drop][]"} />
                  <.button
                    class="mt-6 w-full"
                    type="button"
                    style="info"
                    name={"#{config.name}[clients_upstream_dns_sort][]"}
                    value="new"
                    phx-click={JS.dispatch("change")}
                  >
                    New Resolver
                  </.button>
                  <.error
                    :for={error <- dns_config_errors(@form.source.changes)}
                    data-validation-error-for="clients_upstream_dns"
                  >
                    {error}
                  </.error>
                </div>
              </div>

              <p class="text-sm text-neutral-500">
                <strong>Note:</strong>
                It is highly recommended to specify <strong>both</strong>
                IPv4 and IPv6 addresses when adding upstream resolvers. Otherwise, Clients without IPv4
                or IPv6 connectivity may not be able to resolve DNS queries.
              </p>
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

  def handle_event("change", %{"account" => attrs}, socket) do
    form =
      Accounts.change_account(socket.assigns.account, attrs)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", %{"account" => attrs}, socket) do
    with {:ok, account} <-
           Accounts.update_account(socket.assigns.account, attrs, socket.assigns.subject) do
      form =
        Accounts.change_account(account, %{})
        |> to_form()

      socket = put_flash(socket, :success, "Save successful!")

      {:noreply, assign(socket, account: account, form: form)}
    else
      {:error, changeset} ->
        form =
          changeset
          |> Map.put(:action, :validate)
          |> to_form()

        {:noreply, assign(socket, form: form)}
    end
  end

  defp upstream_dns_empty?(account, form) do
    upstream_dns_changes =
      Map.get(form.source.changes, :config, %{})
      |> Map.get(:changes, %{})
      |> Map.get(:clients_upstream_dns, %{})

    Enum.empty?(account.config.clients_upstream_dns) and Enum.empty?(upstream_dns_changes)
  end

  defp dns_options do
    supported_dns_protocols = Enum.map(Accounts.Config.supported_dns_protocols(), &to_string/1)

    [
      [key: "IP", value: "ip_port"],
      [key: "DNS over TLS", value: "dns_over_tls"],
      [key: "DNS over HTTPS", value: "dns_over_https"]
    ]
    |> Enum.map(fn option ->
      case option[:value] in supported_dns_protocols do
        true -> option
        false -> option ++ [disabled: true]
      end
    end)
  end

  defp dns_config_errors(changes) when changes == %{} do
    []
  end

  defp dns_config_errors(changes) do
    translate_errors(changes.config.errors, :clients_upstream_dns)
  end
end
