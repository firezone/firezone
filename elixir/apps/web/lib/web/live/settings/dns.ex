defmodule Web.Settings.DNS do
  use Web, :live_view
  alias Domain.Accounts

  def mount(_params, _session, socket) do
    account = Accounts.fetch_account_by_id!(socket.assigns.account.id)

    form =
      Accounts.change_account(account, %{})
      |> maybe_append_empty_embed()
      |> to_form()

    socket =
      assign(socket,
        account: account,
        form: form,
        page_title: "DNS"
      )

    {:ok, socket}
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
      <:content>
        <p class="ml-4 mb-4 text-neutral-600">
          Configure the default resolver used by connected Clients in your Firezone account. Queries for
          defined Resources will <strong>always</strong>
          use Firezone's internal DNS. All other queries will
          use the resolver below if configured. If no resolver is configured, the client's default system
          resolver will be used.
        </p>
        <p class="ml-4 mb-4 text-neutral-600">
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
          <h2 class="mb-4 text-xl text-neutral-900">Client DNS</h2>
          <p class="mb-4 text-neutral-500">
            DNS servers will be used in the order they are listed below.
          </p>

          <.form for={@form} phx-submit={:submit} phx-change={:change}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.inputs_for :let={config} field={@form[:config]}>
                  <.inputs_for :let={dns} field={config[:clients_upstream_dns]}>
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
                        <.input
                          label="Address"
                          field={dns[:address]}
                          placeholder="DNS Server Address"
                        />
                      </div>
                    </div>
                  </.inputs_for>
                  <% errors =
                    translate_errors(
                      @form.source.changes.config.errors,
                      :clients_upstream_dns
                    ) %>
                  <.error :for={error <- errors} data-validation-error-for="clients_upstream_dns">
                    <%= error %>
                  </.error>
                </.inputs_for>
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

  def handle_event("change", %{"account" => attrs}, socket) do
    changeset =
      Accounts.change_account(socket.assigns.account, attrs)
      |> maybe_append_empty_embed()
      |> filter_errors()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"account" => attrs}, socket) do
    attrs = remove_empty_servers(attrs)

    with {:ok, account} <-
           Accounts.update_account(socket.assigns.account, attrs, socket.assigns.subject) do
      form =
        Accounts.change_account(account, %{})
        |> maybe_append_empty_embed()
        |> to_form()

      {:noreply, assign(socket, account: account, form: form)}
    else
      {:error, changeset} ->
        changeset =
          changeset
          |> maybe_append_empty_embed()
          |> filter_errors()
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp filter_errors(changeset) do
    update_clients_upstream_dns(changeset, fn
      clients_upstream_dns_changesets ->
        remove_errors(clients_upstream_dns_changesets, :address, "can't be blank")
    end)
  end

  defp remove_errors(changesets, field, message) do
    Enum.map(changesets, fn changeset ->
      errors =
        Enum.filter(changeset.errors, fn
          {^field, {^message, _}} -> false
          {_, _} -> true
        end)

      %{changeset | errors: errors}
    end)
  end

  defp maybe_append_empty_embed(changeset) do
    update_clients_upstream_dns(changeset, fn
      clients_upstream_dns_changesets ->
        last_client_upstream_dns_changeset = List.last(clients_upstream_dns_changesets)

        with true <- last_client_upstream_dns_changeset != nil,
             {_data_or_changes, last_address} <-
               Ecto.Changeset.fetch_field(last_client_upstream_dns_changeset, :address),
             true <- last_address in [nil, ""] do
          clients_upstream_dns_changesets
        else
          _other -> clients_upstream_dns_changesets ++ [%Accounts.Config.ClientsUpstreamDNS{}]
        end
    end)
  end

  defp update_clients_upstream_dns(changeset, cb) do
    config_changeset = Ecto.Changeset.get_embed(changeset, :config)

    clients_upstream_dns_changeset =
      Ecto.Changeset.get_embed(config_changeset, :clients_upstream_dns)

    config_changeset =
      Ecto.Changeset.put_embed(
        config_changeset,
        :clients_upstream_dns,
        cb.(clients_upstream_dns_changeset)
      )

    Ecto.Changeset.put_embed(changeset, :config, config_changeset)
  end

  defp remove_empty_servers(attrs) do
    update_in(attrs, [Access.key("config", %{}), "clients_upstream_dns"], fn
      nil ->
        nil

      servers ->
        Map.filter(servers, fn
          {_index, %{"address" => ""}} -> false
          {_index, %{"address" => nil}} -> false
          _ -> true
        end)
    end)
  end

  defp dns_options do
    options = [
      [key: "IP", value: "ip_port"],
      [key: "DNS over TLS", value: "dns_over_tls"],
      [key: "DNS over HTTPS", value: "dns_over_https"]
    ]

    supported_dns_protocols = Enum.map(Accounts.Config.supported_dns_protocols(), &to_string/1)

    Enum.map(options, fn option ->
      case option[:value] in supported_dns_protocols do
        true -> option
        false -> option ++ [disabled: true]
      end
    end)
  end
end
