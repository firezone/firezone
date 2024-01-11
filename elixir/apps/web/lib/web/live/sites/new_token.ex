defmodule Web.Sites.NewToken do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <- Gateways.fetch_group_by_id(id, socket.assigns.subject) do
      {group, env} =
        if connected?(socket) do
          {:ok, group} =
            Gateways.update_group(%{group | tokens: []}, %{tokens: [%{}]}, socket.assigns.subject)

          :ok = Gateways.subscribe_for_gateways_presence_in_group(group)

          token = Gateways.encode_token!(hd(group.tokens))
          {group, env(token)}
        else
          {group, nil}
        end

      {:ok,
       assign(socket,
         group: group,
         env: env,
         connected?: false,
         selected_tab: "systemd-instructions",
         page_title: "New Site Gateway"
       )}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}"}>
        <%= @group.name %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}/new_token"}>Deploy</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Deploy a new Gateway
      </:title>
      <:help>
        Gateways require outbound access to <code
          class="text-sm bg-neutral-600 text-white px-1 py-0.5 rounded"
          phx-no-format
        >api.firezone.dev:443</code> only. <strong>No inbound firewall rules</strong>
        are required or recommended.
      </:help>
      <:help>
        <.link
          href="http://www.firezone.dev/kb/deploy/gateways?utm_source=product"
          class="text-accent-500 hover:underline"
        >Read the gateway deployment guide for more detailed instructions</.link>.
      </:help>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <div class="text-xl mb-4">
            Select deployment method then follow the instructions below:
          </div>

          <.tabs :if={@env} id="deployment-instructions">
            <:tab
              id="systemd-instructions"
              label="Systemd"
              phx_click="tab_selected"
              selected={@selected_tab == "systemd-instructions"}
            >
              <p class="p-4">
                Copy-paste this command to your server:
              </p>

              <.code_block
                id="code-sample-systemd0"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              ><%= systemd_command(@env) %></.code_block>
            </:tab>
            <:tab
              id="docker-instructions"
              label="Docker"
              phx_click="tab_selected"
              selected={@selected_tab == "docker-instructions"}
            >
              <p class="p-4">
                Copy-paste this command to your server:
              </p>

              <.code_block
                id="code-sample-docker1"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= docker_command(@env) %></.code_block>

              <p class="p-4">
                <strong>Important:</strong>
                If you need IPv6 support, you must <.link
                  href="https://docs.docker.com/config/daemon/ipv6"
                  class={link_style()}
                  target="_blank"
                >enable IPv6 in the Docker daemon</.link>.
              </p>
            </:tab>
          </.tabs>

          <div id="connection-status" class="flex justify-between items-center">
            <p class="text-sm">
              Gateway not connecting? See our <.link
                class="text-accent-500 hover:underline"
                href="https://www.firezone.dev/kb/administer/troubleshooting#gateway-not-connecting"
              >gateway troubleshooting guide</.link>.
            </p>
            <.initial_connection_status
              :if={@env}
              type="gateway"
              navigate={~p"/#{@account}/sites/#{@group}"}
              connected?={@connected?}
            />
          </div>
        </div>
      </:content>
    </.section>
    """
  end

  defp major_minor_version do
    vsn =
      Application.spec(:domain)
      |> Keyword.fetch!(:vsn)
      |> List.to_string()
      |> Version.parse!()

    "#{vsn.major}.#{vsn.minor}"
  end

  defp env(token) do
    api_url_override =
      if api_url = Domain.Config.get_env(:web, :api_url_override) do
        {"FIREZONE_API_URL", api_url}
      end

    [
      {"FIREZONE_ID", Ecto.UUID.generate()},
      {"FIREZONE_TOKEN", token},
      api_url_override,
      {"RUST_LOG",
       Enum.join(
         [
           "firezone_gateway=trace",
           "firezone_tunnel=trace",
           "connlib_shared=trace",
           "tunnel_state=trace",
           "phoenix_channel=debug",
           "webrtc=error",
           "warn"
         ],
         ","
       )}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp docker_command(env) do
    [
      "docker run -d",
      "--restart=unless-stopped",
      "--pull=always",
      "--health-cmd=\"ip link | grep tun-firezone\"",
      "--name=firezone-gateway",
      "--cap-add=NET_ADMIN",
      "--volume /var/lib/firezone",
      "--sysctl net.ipv4.ip_forward=1",
      "--sysctl net.ipv4.conf.all.src_valid_mark=1",
      "--sysctl net.ipv6.conf.all.disable_ipv6=0",
      "--sysctl net.ipv6.conf.all.forwarding=1",
      "--sysctl net.ipv6.conf.default.forwarding=1",
      "--device=\"/dev/net/tun:/dev/net/tun\"",
      Enum.map(env ++ [{"FIREZONE_ENABLE_MASQUERADE", "1"}], fn {key, value} ->
        "--env #{key}=\"#{value}\""
      end),
      "--env FIREZONE_NAME=$(hostname)",
      "#{Domain.Config.fetch_env!(:domain, :docker_registry)}/gateway:#{major_minor_version()}"
    ]
    |> List.flatten()
    |> Enum.join(" \\\n  ")
  end

  defp systemd_command(env) do
    """
    ( function install-firezone {

    # Create firezone user and group
    sudo groupadd -f firezone
    id -u firezone &>/dev/null || sudo useradd -r -g firezone -s /sbin/nologin firezone

    # Create systemd unit file
    sudo cat << EOF > /etc/systemd/system/firezone-gateway.service
    [Unit]
    Description=Firezone Gateway
    After=network.target
    Documentation=https://www.firezone.dev/kb

    [Service]
    Type=simple
    #{Enum.map_join(env, "\n", fn {key, value} -> "Environment=\"#{key}=#{value}\"" end)}
    ExecStartPre=/usr/local/bin/firezone-gateway-init
    ExecStart=/usr/bin/sudo \\\\
      --preserve-env=FIREZONE_NAME,FIREZONE_ID,FIREZONE_TOKEN,FIREZONE_API_URL,RUST_LOG \\\\
      -u firezone \\\\
      -g firezone \\\\
      /usr/local/bin/firezone-gateway
    TimeoutStartSec=3s
    TimeoutStopSec=15s
    Restart=always
    RestartSec=7

    [Install]
    WantedBy=multi-user.target
    EOF

    # Create ExecStartPre script
    sudo cat << EOF > /usr/local/bin/firezone-gateway-init
    #!/bin/sh

    set -ue

    # Download latest version of the gateway if it doesn't already exist
    if [ ! -e /usr/local/bin/firezone-gateway ]; then
      echo "/usr/local/bin/firezone-gateway not found. Downloading latest version..."
      FIREZONE_VERSION=\\$(curl -Ls \\\\
        -H "Accept: application/vnd.github+json" \\\\
        -H "X-GitHub-Api-Version: 2022-11-28" \\\\
        "https://api.github.com/repos/firezone/firezone/releases/latest" | grep '"tag_name":' | sed 's/.*"tag_name": "\\([^"]*\\).*/\\1/'
      )
      [ "\\$FIREZONE_VERSION" = "" ] && echo "[Error] Cannot fetch latest version. Rate-limited by GitHub?" && exit 1
      echo "Downloading Firezone Gateway version \\$FIREZONE_VERSION"
      arch=\\$(uname -m)
      case \\$arch in
        aarch64)
          bin_url="https://github.com/firezone/firezone/releases/download/\\$FIREZONE_VERSION/gateway-arm64"
          ;;
        armv7l)
          bin_url="https://github.com/firezone/firezone/releases/download/\\$FIREZONE_VERSION/gateway-arm"
          ;;
        x86_64)
          bin_url="https://github.com/firezone/firezone/releases/download/\\$FIREZONE_VERSION/gateway-x64"
          ;;
        *)
          echo "Unsupported architecture"
          exit 1
      esac
      curl -Ls \\$bin_url -o /usr/local/bin/firezone-gateway
    else
      echo "/usr/local/bin/firezone-gateway found. Skipping download."
    fi

    # Set proper capabilities and permissions on each start
    chgrp firezone /usr/local/bin/firezone-gateway
    chmod 0750 /usr/local/bin/firezone-gateway
    setcap 'cap_net_admin+eip' /usr/local/bin/firezone-gateway
    mkdir -p /var/lib/firezone
    chown firezone:firezone /var/lib/firezone
    chmod 0775 /var/lib/firezone

    # Enable masquerading for ethernet and wireless interfaces
    iptables -C FORWARD -i tun-firezone -j ACCEPT > /dev/null 2>&1 || iptables -A FORWARD -i tun-firezone -j ACCEPT
    iptables -C FORWARD -o tun-firezone -j ACCEPT > /dev/null 2>&1 || iptables -A FORWARD -o tun-firezone -j ACCEPT
    iptables -t nat -C POSTROUTING -o e+ -j MASQUERADE > /dev/null 2>&1 || iptables -t nat -A POSTROUTING -o e+ -j MASQUERADE
    iptables -t nat -C POSTROUTING -o w+ -j MASQUERADE > /dev/null 2>&1 || iptables -t nat -A POSTROUTING -o w+ -j MASQUERADE
    ip6tables -C FORWARD -i tun-firezone -j ACCEPT > /dev/null 2>&1 || ip6tables -A FORWARD -i tun-firezone -j ACCEPT
    ip6tables -C FORWARD -o tun-firezone -j ACCEPT > /dev/null 2>&1 || ip6tables -A FORWARD -o tun-firezone -j ACCEPT
    ip6tables -t nat -C POSTROUTING -o e+ -j MASQUERADE > /dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -o e+ -j MASQUERADE
    ip6tables -t nat -C POSTROUTING -o w+ -j MASQUERADE > /dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -o w+ -j MASQUERADE

    # Enable packet forwarding
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv4.conf.all.src_valid_mark=1
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sysctl -w net.ipv6.conf.all.forwarding=1
    sysctl -w net.ipv6.conf.default.forwarding=1
    EOF

    # Make ExecStartPre script executable
    sudo chmod +x /usr/local/bin/firezone-gateway-init

    # Reload systemd
    sudo systemctl daemon-reload

    # Enable the service to start on boot
    sudo systemctl enable firezone-gateway

    # Start the service
    sudo systemctl start firezone-gateway

    }
    install-firezone )
    """
  end

  def handle_event("tab_selected", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_tab: id)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "gateway_groups:" <> _group_id}, socket) do
    {:noreply, assign(socket, connected?: true)}
  end
end
