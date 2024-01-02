defmodule Web.Settings.DNS do
  use Web, :live_view
  alias Domain.Config
  alias Domain.Config.Configuration.ClientsUpstreamDNS

  def mount(_params, _session, socket) do
    {:ok, config} = Config.fetch_account_config(socket.assigns.subject)

    form =
      Config.change_account_config(config, %{})
      |> add_new_server()
      |> to_form()

    socket = assign(socket, config: config, form: form)

    {:ok, socket}
  end

  def render(assigns) do
    assigns =
      assign(assigns, :errors, translate_errors(assigns.form.errors, :clients_upstream_dns))

    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/dns"}>DNS Settings</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        DNS
      </:title>
      <:content>
        <p class="ml-4 mb-4 font-medium text-neutral-600">
          Configure the default resolver used by connected Clients in your Firezone account. Queries for
          defined Resources will <strong>always</strong>
          use Firezone's internal DNS. All other queries will
          use the resolver below if configured. If no resolver is configured, the client's default system
          resolver will be used.
        </p>
        <p class="ml-4 mb-4 font-medium text-neutral-600">
          <.link
            class={link_style()}
            href="https://www.firezone.dev/kb/administer/dns?utm_source=product"
            target="_blank"
          >
            Read more about configuring DNS in Firezone.
          </.link>
        </p>
        <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
          <.flash kind={:success} flash={@flash} phx-click="lv:clear-flash" />
          <h2 class="mb-4 text-xl font-bold text-neutral-900">Client DNS</h2>
          <p class="mb-4 text-neutral-500">
            DNS servers will be used in the order they are listed below.
          </p>

          <.form for={@form} phx-submit={:submit} phx-change={:change}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.inputs_for :let={dns} field={@form[:clients_upstream_dns]}>
                  <div class="flex gap-4 items-start mb-2">
                    <div class="w-1/4">
                      <.input
                        type="select"
                        label="Protocol"
                        field={dns[:protocol]}
                        placeholder="Protocol"
                        options={dns_options()}
                        value={dns[:protocol].value}
                      />
                    </div>
                    <div class="w-3/4">
                      <.input label="Address" field={dns[:address]} placeholder="DNS Server Address" />
                    </div>
                  </div>
                </.inputs_for>
                <.error :for={msg <- @errors} data-validation-error-for="clients_upstream_dns">
                  <%= msg %>
                </.error>
              </div>
              <.submit_button>
                Save
              </.submit_button>
            </div>
          </.form>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"configuration" => config_params}, socket) do
    form =
      Config.change_account_config(socket.assigns.config, config_params)
      |> filter_errors()
      |> Map.put(:action, :validate)
      |> to_form()

    socket = assign(socket, form: form)
    {:noreply, socket}
  end

  def handle_event("submit", %{"configuration" => config_params}, socket) do
    attrs = remove_empty_servers(config_params)

    with {:ok, new_config} <-
           Domain.Config.update_config(socket.assigns.config, attrs, socket.assigns.subject) do
      form =
        Config.change_account_config(new_config, %{})
        |> add_new_server()
        |> to_form()

      socket = assign(socket, config: new_config, form: form)
      {:noreply, socket}
    else
      {:error, changeset} ->
        form = to_form(changeset)
        socket = assign(socket, form: form)
        {:noreply, socket}
    end
  end

  defp remove_errors(changeset, field, message) do
    errors =
      Enum.filter(changeset.errors, fn
        {^field, {^message, _}} -> false
        {_, _} -> true
      end)

    %{changeset | errors: errors}
  end

  defp filter_errors(%{changes: %{clients_upstream_dns: clients_upstream_dns}} = changeset) do
    filtered_cs =
      changeset
      |> remove_errors(:clients_upstream_dns, "address can't be blank")

    filtered_dns_cs =
      clients_upstream_dns
      |> Enum.map(fn changeset ->
        remove_errors(changeset, :address, "can't be blank")
      end)

    %{filtered_cs | changes: %{clients_upstream_dns: filtered_dns_cs}}
  end

  defp filter_errors(changeset) do
    changeset
  end

  defp remove_empty_servers(config) do
    servers =
      config["clients_upstream_dns"]
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        case value["address"] do
          nil -> acc
          "" -> acc
          _ -> Map.put(acc, key, value)
        end
      end)

    %{"clients_upstream_dns" => servers}
  end

  defp add_new_server(changeset) do
    existing_servers = Ecto.Changeset.get_embed(changeset, :clients_upstream_dns)

    Ecto.Changeset.put_embed(
      changeset,
      :clients_upstream_dns,
      existing_servers ++ [%{address: ""}]
    )
  end

  defp dns_options do
    options = [
      [key: "IP", value: "ip_port"],
      [key: "DNS over TLS", value: "dns_over_tls"],
      [key: "DNS over HTTPS", value: "dns_over_https"]
    ]

    supported = Enum.map(ClientsUpstreamDNS.supported_protocols(), &to_string/1)

    Enum.map(options, fn option ->
      case option[:value] in supported do
        true -> option
        false -> option ++ [disabled: true]
      end
    end)
  end
end
