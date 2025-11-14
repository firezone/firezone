defmodule Web.Settings.DNS do
  use Web, :live_view
  alias Domain.Accounts

  def mount(_params, _session, socket) do
    with {:ok, account} <-
           Accounts.fetch_account_by_id(socket.assigns.account.id, socket.assigns.subject) do
      form =
        Accounts.change_account(account, %{})
        |> to_form()

      resolver_type = get_resolver_type(account)

      socket =
        assign(socket,
          page_title: "DNS",
          account: account,
          form: form,
          resolver_type: resolver_type
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

              <div class="mb-6">
                <select
                  name="resolver_type"
                  phx-change="change_resolver_type"
                  class="bg-neutral-50 border border-neutral-300 text-neutral-900 text-sm rounded-lg focus:ring-accent-500 focus:border-accent-500 block w-full p-2.5"
                >
                  <option value="system" selected={@resolver_type == :system}>
                    System Resolvers
                  </option>
                  <option value="google" selected={@resolver_type == :google}>
                    Google (DNS-over-HTTPS)
                  </option>
                  <option value="cloudflare" selected={@resolver_type == :cloudflare}>
                    Cloudflare (DNS-over-HTTPS)
                  </option>
                  <option value="quad9" selected={@resolver_type == :quad9}>
                    Quad9 (DNS-over-HTTPS)
                  </option>
                  <option value="opendns" selected={@resolver_type == :opendns}>
                    OpenDNS (DNS-over-HTTPS)
                  </option>
                  <option value="custom_do53" selected={@resolver_type == :custom_do53}>
                    Custom (UDP/TCP on port 53)
                  </option>
                </select>
                <p class="mt-2 text-sm text-neutral-500">
                  {resolver_type_description(@resolver_type)}
                </p>
              </div>

              <input
                type="hidden"
                name={"#{config.name}[upstream_doh_provider]"}
                value={
                  if @resolver_type in [:google, :cloudflare, :quad9, :opendns],
                    do: @resolver_type,
                    else: ""
                }
              />

              <div
                :if={@resolver_type == :custom_do53}
                class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6"
              >
                <div>
                  <p :if={not upstream_dns_empty?(@account, @form)} class="mb-4 text-neutral-500">
                    Upstream resolvers will be used by Client devices in the order they are listed below.
                  </p>

                  <p :if={upstream_dns_empty?(@account, @form)} class="mb-4 text-neutral-500">
                    No upstream resolvers have been configured. Click <strong>New Resolver</strong>
                    to add one.
                  </p>

                  <.inputs_for :let={dns} field={config[:upstream_do53]}>
                    <input
                      type="hidden"
                      name={"#{config.name}[upstream_do53_sort][]"}
                      value={dns.index}
                    />

                    <div class="flex gap-4 items-start mb-2">
                      <div class="flex-grow">
                        <.input label="IP Address" field={dns[:address]} placeholder="E.g. 1.1.1.1" />
                      </div>
                      <div class="justify-self-end">
                        <div class="pt-7">
                          <button
                            type="button"
                            name={"#{config.name}[upstream_do53_drop][]"}
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

                  <input type="hidden" name={"#{config.name}[upstream_do53_drop][]"} />
                  <.button
                    class="mt-6 w-full"
                    type="button"
                    style="info"
                    name={"#{config.name}[upstream_do53_sort][]"}
                    value="new"
                    phx-click={JS.dispatch("change")}
                  >
                    New Resolver
                  </.button>
                  <.error
                    :for={error <- dns_config_errors(@form.source.changes)}
                    data-validation-error-for="upstream_do53"
                  >
                    {error}
                  </.error>

                  <p class="mt-4 text-sm text-neutral-500">
                    <strong>Note:</strong>
                    It is highly recommended to specify <strong>both</strong>
                    IPv4 and IPv6 addresses when adding upstream resolvers. Otherwise, Clients without IPv4
                    or IPv6 connectivity may not be able to resolve DNS queries.
                  </p>
                </div>
              </div>
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

  def handle_event("change_resolver_type", %{"resolver_type" => type}, socket) do
    resolver_type = String.to_existing_atom(type)

    attrs =
      case resolver_type do
        :system ->
          %{config: %{upstream_do53: [], upstream_doh_provider: nil}}

        provider when provider in [:google, :cloudflare, :quad9, :opendns] ->
          %{config: %{upstream_do53: [], upstream_doh_provider: provider}}

        :custom_do53 ->
          # Keep existing Do53 servers or add an empty one
          existing = socket.assigns.account.config.upstream_do53 || []
          servers = if Enum.empty?(existing), do: [%{address: ""}], else: existing
          %{config: %{upstream_do53: servers, upstream_doh_provider: nil}}
      end

    form =
      Accounts.change_account(socket.assigns.account, attrs)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form, resolver_type: resolver_type)}
  end

  def handle_event("change", %{"account" => attrs}, socket) do
    form =
      Accounts.change_account(socket.assigns.account, attrs)
      |> Map.put(:action, :validate)
      |> to_form()

    resolver_type = get_resolver_type_from_attrs(attrs)

    {:noreply, assign(socket, form: form, resolver_type: resolver_type)}
  end

  def handle_event("submit", %{"account" => attrs}, socket) do
    # Clean up attrs based on resolver type to ensure mutual exclusivity
    cleaned_attrs = clean_dns_attrs(attrs, socket.assigns.resolver_type)

    with {:ok, account} <-
           Accounts.update_account(socket.assigns.account, cleaned_attrs, socket.assigns.subject) do
      form =
        Accounts.change_account(account, %{})
        |> to_form()

      resolver_type = get_resolver_type(account)
      socket = put_flash(socket, :success, "Save successful!")

      {:noreply, assign(socket, account: account, form: form, resolver_type: resolver_type)}
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
      |> Map.get(:upstream_do53, %{})

    Enum.empty?(account.config.upstream_do53) and Enum.empty?(upstream_dns_changes)
  end

  defp get_resolver_type(account) do
    config = account.config

    cond do
      config.upstream_doh_provider != nil ->
        config.upstream_doh_provider

      not Enum.empty?(config.upstream_do53 || []) ->
        :custom_do53

      true ->
        :system
    end
  end

  defp get_resolver_type_from_attrs(attrs) do
    config = Map.get(attrs, "config", %{})
    provider = Map.get(config, "upstream_doh_provider")
    do53 = Map.get(config, "upstream_do53", [])

    cond do
      provider != nil and provider != "" ->
        String.to_existing_atom(provider)

      not Enum.empty?(do53) ->
        :custom_do53

      true ->
        :system
    end
  end

  defp resolver_type_description(type) do
    case type do
      :system ->
        "Use the operating system's default DNS resolvers. Clients will use their local network's DNS settings."

      :google ->
        "Use Google Public DNS with DNS-over-HTTPS."

      :cloudflare ->
        "Use Cloudflare DNS with DNS-over-HTTPS."

      :quad9 ->
        "Use Quad9 DNS with DNS-over-HTTPS."

      :opendns ->
        "Use OpenDNS with DNS-over-HTTPS."

      :custom_do53 ->
        "Configure custom DNS servers. Enter IP addresses of DNS resolvers to use."
    end
  end

  defp clean_dns_attrs(attrs, resolver_type) do
    config = Map.get(attrs, "config", %{})

    cleaned_config =
      case resolver_type do
        :system ->
          # Clear both Do53 and DoH
          config
          |> Map.put("upstream_do53", [])
          |> Map.put("upstream_doh_provider", "")

        provider when provider in [:google, :cloudflare, :quad9, :opendns] ->
          # Clear Do53, keep DoH
          Map.put(config, "upstream_do53", [])

        :custom_do53 ->
          # Clear DoH, keep Do53
          Map.put(config, "upstream_doh_provider", "")
      end

    Map.put(attrs, "config", cleaned_config)
  end

  defp dns_config_errors(changes) when changes == %{} do
    []
  end

  defp dns_config_errors(changes) do
    translate_errors(changes.config.errors, :upstream_do53)
  end
end
