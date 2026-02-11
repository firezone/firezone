defmodule PortalWeb.Sites.NewToken do
  use PortalWeb, :live_view
  alias __MODULE__.Database

  def mount(%{"id" => id}, _session, socket) do
    site = Database.get_site!(id, socket.assigns.subject)

    {site, token, env} =
      if connected?(socket) do
        {:ok, token, encoded_token} = Database.create_token(site, socket.assigns.subject)
        :ok = Portal.Presence.Gateways.Site.subscribe(site.id)
        {site, token, env(encoded_token)}
      else
        {site, nil, nil}
      end

    {:ok,
     assign(socket,
       page_title: "New Site Gateway",
       site: site,
       token: token,
       env: env,
       connected?: false
     )}
  end

  def handle_params(params, uri, socket) do
    {:noreply,
     assign(socket,
       uri: uri,
       selected_tab: Map.get(params, "method", "debian-instructions")
     )}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@site}"}>
        {@site.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@site}/new_token"}>Deploy</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Deploy a new Gateway
      </:title>
      <:help>
        Gateways require egress connectivity to the control plane API and relay servers.
        <strong>No ingress firewall rules</strong>
        are required or recommended.
      </:help>
      <:help>
        Read the
        <.website_link path="/kb/deploy/gateways">
          Gateway deployment guide
        </.website_link>
        for more detailed instructions.
      </:help>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <div class="text-xl mb-4">
            Select deployment method then follow the instructions below:
          </div>

          <.tabs :if={@env} id="deployment-instructions">
            <:tab
              id="debian-instructions"
              icon="os-debian"
              label="Debian / Ubuntu"
              phx_click="tab_selected"
              selected={@selected_tab == "debian-instructions"}
            >
              <p class="p-6 font-semibold">
                Step 1: Add the Firezone package repository.
              </p>

              <.code_block
                id="code-sample-debian1"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= debian_command_apt_repository() %></.code_block>

              <p class="p-6 font-semibold">
                Step 2: Install the Gateway:
              </p>

              <.code_block
                id="code-sample-debian2"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= debian_command_install() %></.code_block>

              <p class="p-6 font-semibold">
                Step 3: Configure a token:
              </p>

              <.code_block
                id="code-sample-debian4"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= debian_command_authenticate() %></.code_block>

              <p class="p-6 font-semibold">
                Step 4: Use the below token when prompted:
              </p>

              <.code_block
                id="code-sample-debian3"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= token(@env) %></.code_block>

              <p class="p-6 font-semibold">
                Step 5: You are now ready to manage the Gateway using the <code>firezone</code> CLI.
              </p>
            </:tab>
            <:tab
              id="systemd-instructions"
              icon="hero-command-line"
              label="systemd"
              phx_click="tab_selected"
              selected={@selected_tab == "systemd-instructions"}
            >
              <p class="p-6">
                Copy-paste this command to your server:
              </p>

              <.code_block
                id="code-sample-systemd0"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              ><%= systemd_command(@env) %></.code_block>

              <p class="p-6">
                <strong>Important:</strong>
                Make sure that the <code>iptables</code>
                and <code>ip6tables</code>
                commands are available on your system.
              </p>
            </:tab>
            <:tab
              id="docker-instructions"
              icon="docker"
              label="Docker"
              phx_click="tab_selected"
              selected={@selected_tab == "docker-instructions"}
            >
              <p class="p-6">
                Copy-paste this command to your server:
              </p>

              <.code_block
                id="code-sample-docker1"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= docker_command(@env) %></.code_block>

              <p class="p-6">
                Using Docker Compose? See our
                <.website_link path="/kb/automate/docker-compose">sample compose file.</.website_link>
              </p>

              <p class="p-6 pt-0">
                <strong>Important:</strong>
                If you need IPv6 support, you must <.link
                  href="https://docs.docker.com/config/daemon/ipv6"
                  class={link_style()}
                  target="_blank"
                >enable IPv6 in the Docker daemon</.link>.
              </p>
            </:tab>
            <:tab
              id="terraform-instructions"
              icon="terraform"
              label="Terraform"
              phx_click="tab_selected"
              selected={@selected_tab == "terraform-instructions"}
            >
              <p class="p-6 font-semibold">
                Step 1: Copy the token shown below to a safe location.
              </p>

              <.code_block
                id="code-sample-terraform"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= token(@env) %></.code_block>

              <p class="p-6 font-semibold">
                Step 2: Follow one of our
                <.website_link path="/kb/automate">Terraform guides</.website_link>
                to deploy a Gateway for your cloud provider.
              </p>
            </:tab>
            <:tab
              id="binary-instructions"
              icon="hero-wrench-screwdriver"
              label="Custom"
              phx_click="tab_selected"
              selected={@selected_tab == "binary-instructions"}
            >
              <p class="p-6 font-semibold">
                Step 1:
                <.website_link path="/changelog">
                  Download the latest binary
                </.website_link>
                for your architecture.
              </p>

              <p class="p-6 pt-0 font-semibold">
                Step 2: Set required environment variables:
              </p>

              <.code_block
                id="code-sample-binary1"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= manual_command_env(@env) %></.code_block>

              <p class="p-6 font-semibold">
                Step 3: Enable packet forwarding for IPv4 and IPv6:
              </p>

              <.code_block
                id="code-sample-binary2"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= manual_command_forwarding() %></.code_block>

              <p class="p-6 font-semibold">
                Step 4: Enable masquerading for ethernet and WiFi interfaces:
              </p>

              <.code_block
                id="code-sample-binary3"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= manual_command_masquerading() %></.code_block>

              <p class="p-6 font-semibold">
                Step 5: Run the binary you downloaded in Step 1:
              </p>

              <.code_block
                id="code-sample-binary4"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= "sudo ./firezone-gateway-<version>-<architecture>" %></.code_block>

              <p class="p-6">
                <strong>Important:</strong>
                Make sure to save the <code>FIREZONE_TOKEN</code>
                shown above to a secure location before continuing. It won't be shown again.
              </p>
            </:tab>
          </.tabs>

          <div id="connection-status" class="flex justify-between items-center">
            <p class="text-sm">
              Gateway not connecting? See our
              <.website_link path="/kb/administer/troubleshooting" fragment="gateway-not-connecting">
                Gateway troubleshooting guide.
              </.website_link>
            </p>
            <.initial_connection_status
              :if={@env}
              type="gateway"
              navigate={~p"/#{@account}/sites/#{@site}"}
              connected?={@connected?}
            />
          </div>
        </div>
      </:content>
    </.section>
    """
  end

  defp env(encoded_token) do
    api_url_override =
      if api_url = Portal.Config.get_env(:portal, :api_url_override) do
        {"FIREZONE_API_URL", api_url}
      end

    [
      {"FIREZONE_ID", Ecto.UUID.generate()},
      {"FIREZONE_TOKEN", encoded_token},
      api_url_override
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp token(env) do
    {"FIREZONE_TOKEN", value} = List.keyfind(env, "FIREZONE_TOKEN", 0)

    value
  end

  defp debian_command_apt_repository do
    """
    sudo mkdir --parents /etc/apt/keyrings
    wget -qO- https://artifacts.firezone.dev/apt/key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/firezone.gpg
    echo "deb [signed-by=/etc/apt/keyrings/firezone.gpg] https://artifacts.firezone.dev/apt/ stable main" | sudo tee /etc/apt/sources.list.d/firezone.list > /dev/null
    """
  end

  defp debian_command_install do
    """
    sudo apt update
    sudo apt install firezone-gateway
    """
  end

  defp debian_command_authenticate do
    """
    sudo firezone gateway authenticate
    """
  end

  defp docker_command(env) do
    [
      "docker run -d",
      "--restart=unless-stopped",
      "--pull=always",
      "--health-cmd=\"ip link | grep tun-firezone\"",
      "--name=firezone-gateway",
      "--cap-add=NET_ADMIN",
      "--sysctl net.ipv4.ip_forward=1",
      "--sysctl net.ipv4.conf.all.src_valid_mark=1",
      "--sysctl net.ipv6.conf.all.disable_ipv6=0",
      "--sysctl net.ipv6.conf.all.forwarding=1",
      "--sysctl net.ipv6.conf.default.forwarding=1",
      "--device=\"/dev/net/tun:/dev/net/tun\"",
      Enum.map(env, fn {key, value} ->
        "--env #{key}=\"#{value}\""
      end),
      "--env FIREZONE_NAME=$(hostname)",
      "--env RUST_LOG=info",
      "#{Portal.Config.fetch_env!(:portal, :docker_registry)}/gateway:1"
    ]
    |> List.flatten()
    |> Enum.join(" \\\n  ")
  end

  defp systemd_command(env) do
    """
    #{Enum.map_join(env, " \\\n", fn {key, value} -> "#{key}=\"#{value}\"" end)} \\
      bash <(curl -fsSL https://raw.githubusercontent.com/firezone/firezone/main/scripts/gateway-systemd-install.sh)
    """
  end

  defp manual_command_masquerading do
    """
    sudo iptables -C FORWARD -i tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo iptables -A FORWARD -i tun-firezone -j ACCEPT
    sudo iptables -C FORWARD -o tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo iptables -A FORWARD -o tun-firezone -j ACCEPT
    sudo iptables -t nat -C POSTROUTING -o e+ -j MASQUERADE > /dev/null 2>&1 || sudo iptables -t nat -A POSTROUTING -o e+ -j MASQUERADE
    sudo iptables -t nat -C POSTROUTING -o w+ -j MASQUERADE > /dev/null 2>&1 || sudo iptables -t nat -A POSTROUTING -o w+ -j MASQUERADE
    sudo ip6tables -C FORWARD -i tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo ip6tables -A FORWARD -i tun-firezone -j ACCEPT
    sudo ip6tables -C FORWARD -o tun-firezone -j ACCEPT > /dev/null 2>&1 || sudo ip6tables -A FORWARD -o tun-firezone -j ACCEPT
    sudo ip6tables -t nat -C POSTROUTING -o e+ -j MASQUERADE > /dev/null 2>&1 || sudo ip6tables -t nat -A POSTROUTING -o e+ -j MASQUERADE
    sudo ip6tables -t nat -C POSTROUTING -o w+ -j MASQUERADE > /dev/null 2>&1 || sudo ip6tables -t nat -A POSTROUTING -o w+ -j MASQUERADE
    """
  end

  defp manual_command_forwarding do
    """
    sudo sysctl -w net.ipv4.ip_forward=1
    sudo sysctl -w net.ipv4.conf.all.src_valid_mark=1
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sudo sysctl -w net.ipv6.conf.all.forwarding=1
    sudo sysctl -w net.ipv6.conf.default.forwarding=1
    """
  end

  defp manual_command_env(env) do
    """
    RUST_LOG=info
    #{Enum.map_join(env, "\n", fn {key, value} -> "#{key}=#{value}" end)}
    """
  end

  def handle_event("tab_selected", %{"id" => id}, socket) do
    socket
    |> assign(selected_tab: id)
    |> update_query_params(fn query_params ->
      Map.put(query_params, "method", id)
    end)
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:sites:" <> _site_id,
          payload: %{joins: joins}
        },
        socket
      ) do
    if socket.assigns.connected? do
      {:noreply, socket}
    else
      connected? =
        joins
        |> Enum.any?(fn {_gateway_id, %{metas: metas}} ->
          Enum.any?(metas, fn meta ->
            Map.get(meta, :token_id) == socket.assigns.token.id
          end)
        end)

      {:noreply, assign(socket, connected?: connected?)}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_site!(id, subject) do
      from(s in Portal.Site, as: :sites)
      |> where([sites: s], s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def create_token(site, subject) do
      with {:ok, token} <- Portal.Authentication.create_gateway_token(site, subject) do
        {:ok, %{token | secret_fragment: nil}, Portal.Authentication.encode_fragment!(token)}
      end
    end
  end
end
