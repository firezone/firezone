defmodule Web.RelayGroups.NewToken do
  use Web, :live_view
  alias Domain.{Accounts, Relays}

  def mount(%{"id" => id}, _session, socket) do
    with true <- Accounts.self_hosted_relays_enabled?(socket.assigns.account),
         {:ok, group} <-
           Relays.fetch_group_by_id(id, socket.assigns.subject,
             filter: [
               deleted?: false
             ]
           ) do
      {group, token, env} =
        if connected?(socket) do
          {:ok, token, encoded_token} = Relays.create_token(group, %{}, socket.assigns.subject)
          :ok = Relays.subscribe_to_relays_presence_in_group(group)
          {group, token, env(encoded_token)}
        else
          {group, nil, nil}
        end

      {:ok,
       assign(socket,
         group: group,
         token: token,
         env: env,
         connected?: false,
         selected_tab: "systemd-instructions",
         page_title: "New Relay"
       )}
    else
      _other -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/relay_groups"}>Relays</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/#{@group}"}>
        {@group.name}
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/#{@group}/new_token"}>Deploy</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title>
        Deploy Relay
      </:title>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <div class="text-xl mb-2">
            Select deployment method:
          </div>

          <.tabs :if={@env} id="deployment-instructions">
            <:tab
              id="systemd-instructions"
              label="systemd"
              phx_click="tab_selected"
              selected={@selected_tab == "systemd-instructions"}
            >
              <p class="p-4">
                1. Create an unprivileged user and group to run the relay:
              </p>

              <.code_block
                id="code-sample-systemd0"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              >sudo groupadd -f firezone \
    && id -u firezone &>/dev/null || sudo useradd -r -g firezone -s /sbin/nologin firezone</.code_block>

              <p class="p-4">
                2. Create a new systemd unit file:
              </p>

              <.code_block
                id="code-sample-systemd1"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              >sudo nano /etc/systemd/system/firezone-relay.service</.code_block>

              <p class="p-4">
                3. Copy-paste the following contents into the file and replace
                <code>PUBLIC_IP4_ADDR</code>
                and <code>PUBLIC_IP6_ADDR</code>
                with your public IP addresses:
              </p>

              <.code_block
                id="code-sample-systemd2"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= systemd_command(@env) %></.code_block>

              <p class="p-4">
                4. Save by pressing <kbd>Ctrl</kbd>+<kbd>X</kbd>, then <kbd>Y</kbd>, then <kbd>Enter</kbd>.
              </p>

              <p class="p-4">
                5. Reload systemd configuration:
              </p>

              <.code_block
                id="code-sample-systemd4"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              >sudo systemctl daemon-reload</.code_block>

              <p class="p-4">
                6. Start the service:
              </p>

              <.code_block
                id="code-sample-systemd5"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              >sudo systemctl start firezone-relay</.code_block>

              <p class="p-4">
                7. Enable the service to start on boot:
              </p>

              <.code_block
                id="code-sample-systemd6"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              >sudo systemctl enable firezone-relay</.code_block>
              <hr />

              <h4 class="p-4 text-xl font-semibold">
                Troubleshooting
              </h4>

              <p class="p-4">
                Check the status of the service:
              </p>

              <.code_block
                id="code-sample-systemd7"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              >sudo systemctl status firezone-relay</.code_block>

              <p class="p-4">
                Check the logs:
              </p>

              <.code_block
                id="code-sample-systemd8"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              >sudo journalctl -u firezone-relay.service</.code_block>
            </:tab>
            <:tab
              id="docker-instructions"
              label="Docker"
              phx_click="tab_selected"
              selected={@selected_tab == "docker-instructions"}
            >
              <p class="p-4">
                Copy-paste this command to your server and replace <code>PUBLIC_IP4_ADDR</code>
                and <code>PUBLIC_IP6_ADDR</code>
                with your public IP addresses:
              </p>

              <.code_block
                id="code-sample-docker1"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= docker_command(@env) %></.code_block>

              <hr />

              <h4 class="p-4 text-xl font-semibold">
                Troubleshooting
              </h4>

              <p class="p-4">
                Check the container status:
              </p>

              <.code_block
                id="code-sample-docker2"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              >docker ps --filter "name=firezone-relay"</.code_block>

              <p class="p-4">
                Check the container logs:
              </p>

              <.code_block
                id="code-sample-docker3"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
              >docker logs firezone-relay</.code_block>
            </:tab>
          </.tabs>

          <div id="connection-status" class="flex justify-between items-center">
            <p class="text-sm">
              Relay not connecting? See our
              <.website_link path="/kb/administer/troubleshooting">
                relay troubleshooting guide
              </.website_link>.
            </p>
            <.initial_connection_status
              :if={@env}
              type="relay"
              navigate={~p"/#{@account}/relay_groups/#{@group}"}
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
      if api_url = Domain.Config.get_env(:web, :api_url_override) do
        {"FIREZONE_API_URL", api_url}
      end

    [
      {"FIREZONE_ID", Ecto.UUID.generate()},
      {"FIREZONE_TOKEN", encoded_token},
      {"PUBLIC_IP4_ADDR", "YOU_MUST_SET_THIS_VALUE"},
      {"PUBLIC_IP6_ADDR", "YOU_MUST_SET_THIS_VALUE"},
      api_url_override,
      {"RUST_LOG",
       Enum.join(
         [
           "firezone_relay=info",
           "firezone_tunnel=info",
           "connlib_shared=info",
           "tunnel_state=info",
           "phoenix_channel=info",
           "snownet=info",
           "str0m=info",
           "warn"
         ],
         ","
       )},
      {"LOG_FORMAT", "google-cloud"}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp docker_command(env) do
    [
      "docker run -d",
      "--restart=unless-stopped",
      "--pull=always",
      "--health-cmd=\"cat /proc/net/udp | grep D96\"",
      "--name=firezone-relay",
      "--cap-add=NET_ADMIN",
      "--volume /var/lib/firezone",
      "--sysctl net.ipv4.ip_forward=1",
      "--sysctl net.ipv4.conf.all.src_valid_mark=1",
      "--sysctl net.ipv6.conf.all.disable_ipv6=0",
      "--sysctl net.ipv6.conf.all.forwarding=1",
      "--sysctl net.ipv6.conf.default.forwarding=1",
      "--device=\"/dev/net/tun:/dev/net/tun\"",
      Enum.map(env, fn {key, value} -> "--env #{key}=\"#{value}\"" end),
      "--env FIREZONE_NAME=$(hostname)",
      "#{Domain.Config.fetch_env!(:domain, :docker_registry)}/relay:latest"
    ]
    |> List.flatten()
    |> Enum.join(" \\\n  ")
  end

  defp systemd_command(env) do
    """
    [Unit]
    Description=Firezone Relay
    After=network.target
    Documentation=https://www.firezone.dev/kb

    [Service]
    Type=exec
    DynamicUser=true
    User=firezone-relay

    WorkingDirectory=/var/lib/firezone-relay
    StateDirectory=firezone-relay

    LockPersonality=true
    MemoryDenyWriteExecute=true
    NoNewPrivileges=true
    PrivateMounts=true
    PrivateTmp=true
    PrivateUsers=false
    ProcSubset=pid
    ProtectClock=true
    ProtectControlGroups=true
    ProtectHome=true
    ProtectHostname=true
    ProtectKernelLogs=true
    ProtectKernelModules=true
    ProtectKernelTunables=true
    ProtectProc=invisible
    ProtectSystem=strict
    RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
    RestrictNamespaces=true
    RestrictRealtime=true
    RestrictSUIDSGID=true
    SystemCallArchitectures=native
    SystemCallFilter=@system-service
    UMask=077

    #{Enum.map_join(env, "\n", fn {key, value} -> "Environment=\"#{key}=#{value}\"" end)}
    ExecStartPre=/bin/sh -c 'set -ue; \\
      mkdir -p bin; \\
      if [ ! -e bin/firezone-relay ]; then \\
        FIREZONE_VERSION=$(curl -Ls \\
          -H "Accept: application/vnd.github+json" \\
          -H "X-GitHub-Api-Version: 2022-11-28" \\
          "https://api.github.com/repos/firezone/firezone/releases/latest" | \\
          grep "\\\\"tag_name\\\\":" | sed "s/.*\\\\"tag_name\\\\": \\\\"\\([^\\\\"\\\\]*\\).*/\\1/" \\
        ); \\
        [ "$FIREZONE_VERSION" = "" ] && echo "[Error] Cannot fetch latest version, rate limited by GitHub?" && exit 1; \\
        echo "Downloading Firezone Relay version $FIREZONE_VERSION"; \\
        arch=$(uname -m); \\
        case $arch in \\
          aarch64) \\
            bin_url="https://github.com/firezone/firezone/releases/download/$FIREZONE_VERSION/relay-arm64" ;; \\
          armv7l) \\
            bin_url="https://github.com/firezone/firezone/releases/download/$FIREZONE_VERSION/relay-arm" ;; \\
          x86_64) \\
            bin_url="https://github.com/firezone/firezone/releases/download/$FIREZONE_VERSION/relay-x64" ;; \\
          *) \\
            echo "Unsupported architecture"; \\
            exit 1 ;; \\
        esac; \\
        curl -Ls "$bin_url" -o bin/firezone-relay; \\
        chmod 750 bin/firezone-relay; \\
      fi; \\
    '
    ExecStart=/var/lib/firezone-relay/bin/firezone-relay
    TimeoutStartSec=3s
    TimeoutStopSec=15s
    Restart=always
    RestartSec=7

    [Install]
    WantedBy=multi-user.target
    """
  end

  def handle_event("tab_selected", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_tab: id)}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: "presences:group_relays:" <> _group_id,
          payload: %{joins: joins}
        },
        socket
      ) do
    if socket.assigns.connected? do
      {:noreply, socket}
    else
      connected? =
        joins
        |> Map.keys()
        |> Enum.any?(fn id ->
          relay = Relays.fetch_relay_by_id!(id)
          socket.assigns.token.id == relay.last_used_token_id
        end)

      {:noreply, assign(socket, connected?: connected?)}
    end
  end
end
