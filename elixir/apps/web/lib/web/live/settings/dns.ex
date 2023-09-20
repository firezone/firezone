defmodule Web.Settings.DNS do
  use Web, :live_view

  alias Domain.Config

  defp pretty_print_addrs([]), do: ""
  defp pretty_print_addrs(addrs), do: Enum.join(addrs, ", ")

  defp addrs_to_list(nil), do: []

  defp addrs_to_list(addrs_str) do
    addrs_str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
  end

  defp config_to_params(config) do
    addrs_str = Enum.join(config.clients_upstream_dns, ", ")
    resolver = if addrs_str == "", do: "system", else: "custom"

    %{
      "resolver" => resolver,
      "clients_upstream_dns" => addrs_str
    }
  end

  defp params_to_form(params, errors \\ []) do
    addrs =
      case params["resolver"] do
        "system" -> []
        "custom" -> addrs_to_list(params["clients_upstream_dns"])
        _ -> []
      end

    to_form(
      %{
        "resolver" => params["resolver"],
        "clients_upstream_dns" => addrs
      },
      errors: errors
    )
  end

  def mount(_params, _session, socket) do
    resolver_opts = %{"System Default" => "system", "Custom" => "custom"}
    {:ok, config} = Config.fetch_account_config(socket.assigns.subject)
    form = config_to_params(config) |> params_to_form()

    socket =
      assign(socket,
        config: config,
        resolver_opts: resolver_opts,
        form: form
      )

    {:ok, socket}
  end

  def handle_event("change", params, socket) do
    form = params_to_form(params)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", params, socket) do
    addrs =
      case params["resolver"] do
        "system" -> []
        "custom" -> addrs_to_list(params["clients_upstream_dns"])
        _ -> []
      end

    case Config.update_config(
           socket.assigns.config,
           %{"clients_upstream_dns" => addrs},
           socket.assigns.subject
         ) do
      {:ok, updated_config} ->
        form = config_to_params(updated_config) |> params_to_form() |> dbg()

        socket =
          socket
          |> assign(form: form, config: updated_config)
          |> put_flash(:success, "DNS settings have been updated!")

        {:noreply, socket}

      {:error, changeset} ->
        form =
          params
          |> Map.put("action", "validate")
          |> params_to_form(changeset.errors)

        {:noreply, assign(socket, form: form)}
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/settings/dns"}>DNS Settings</.breadcrumb>
    </.breadcrumbs>
    <.header>
      <:title>
        DNS
      </:title>
    </.header>
    <p class="ml-4 mb-4 font-medium bg-gray-50 dark:bg-gray-800 text-gray-600 dark:text-gray-500">
      Configure the default resolver used by connected Clients in your Firezone network. Queries for
      defined Resources will <strong>always</strong>
      use Firezone's internal DNS. All other queries will
      use the resolver configured below.
    </p>
    <p class="ml-4 mb-4 font-medium bg-gray-50 dark:bg-gray-800 text-gray-600 dark:text-gray-500">
      <.link
        class="text-blue-600 dark:text-blue-500 hover:underline"
        href="https://www.firezone.dev/docs/architecture/dns"
        target="_blank"
      >
        Read more about how DNS works in Firezone.
        <.icon name="hero-arrow-top-right-on-square" class="-ml-1 mb-3 w-3 h-3" />
      </.link>
    </p>
    <section class="bg-white dark:bg-gray-900">
      <div class="max-w-2xl px-4 py-8 mx-auto lg:py-16">
        <.flash kind={:success} flash={@flash} phx-click="lv:clear-flash" />
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Client DNS</h2>
        <.form for={@form} phx-change={:change} phx-submit={:submit}>
          <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
            <div>
              <.input
                label="Resolver"
                type="select"
                field={@form[:resolver]}
                options={@resolver_opts}
                required
              />
            </div>

            <div>
              <.input
                label="Address"
                field={@form[:clients_upstream_dns]}
                value={pretty_print_addrs(@form[:clients_upstream_dns].value)}
                placeholder="DNS Server Address"
                disabled={@form[:resolver].value == "system"}
              />
              <p id="address-explanation" class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                IP addresses, FQDNs, and DNS-over-HTTPS (DoH) addresses are supported.
              </p>
            </div>
          </div>
          <.submit_button>
            Save
          </.submit_button>
        </.form>
      </div>
    </section>
    """
  end
end
