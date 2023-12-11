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
         selected_tab: "docker-instructions"
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
        Deploy your Gateway
      </:title>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <div class="text-xl mb-4">
            Select deployment method:
          </div>

          <.tabs :if={@env} id="deployment-instructions">
            <:tab
              id="docker-instructions"
              label="Docker"
              phx_click="tab_selected"
              selected={@selected_tab == "docker-instructions"}
            >
              <p class="p-4">
                Copy-paste this command to your server:
              </p>

              <.code_block id="code-sample-docker1" class="w-full" phx-no-format phx-update="ignore"><%= docker_command(@env) %></.code_block>
            </:tab>
            <:tab
              id="systemd-instructions"
              label="Systemd"
              phx_click="tab_selected"
              selected={@selected_tab == "systemd-instructions"}
            >
              <p class="p-4">
                1. Create a new systemd unit file:
              </p>

              <.code_block id="code-sample-systemd1" class="w-full" phx-no-format>sudo nano /etc/systemd/system/firezone-gateway.service</.code_block>

              <p class="p-4">
                2. Copy-paste the following contents into the file:
              </p>

              <.code_block
                id="code-sample-systemd2"
                class="w-full rounded-b"
                phx-no-format
                phx-update="ignore"
              ><%= systemd_command(@env) %></.code_block>

              <p class="p-4">
                3. Save by pressing <kbd>Ctrl</kbd>+<kbd>X</kbd>, then <kbd>Y</kbd>, then <kbd>Enter</kbd>.
              </p>

              <p class="p-4">
                4. Reload systemd configuration:
              </p>

              <.code_block id="code-sample-systemd4" class="w-full" phx-no-format>sudo systemctl daemon-reload</.code_block>

              <p class="p-4">
                5. Start the service:
              </p>

              <.code_block id="code-sample-systemd5" class="w-full" phx-no-format>sudo systemctl start firezone-gateway</.code_block>

              <p class="p-4">
                6. Enable the service to start on boot:
              </p>

              <.code_block id="code-sample-systemd6" class="w-full" phx-no-format>sudo systemctl enable firezone-gateway</.code_block>
            </:tab>
          </.tabs>

          <div class="flex justify-between items-center">
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

  defp version do
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
      {"FIREZONE_ENABLE_MASQUERADE", "1"},
      api_url_override,
      {"RUST_LOG", "warn"}
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
      "--volume /etc/firezone",
      "--sysctl net.ipv4.ip_forward=1",
      "--sysctl net.ipv4.conf.all.src_valid_mark=1",
      "--sysctl net.ipv6.conf.all.disable_ipv6=0",
      "--sysctl net.ipv6.conf.all.forwarding=1",
      "--sysctl net.ipv6.conf.default.forwarding=1",
      "--device=\"/dev/net/tun:/dev/net/tun\"",
      Enum.map(env, fn {key, value} -> "--env #{key}=\"#{value}\"" end),
      "--env FIREZONE_NAME=$(hostname)",
      "#{Domain.Config.fetch_env!(:domain, :docker_registry)}/gateway:#{version()}"
    ]
    |> List.flatten()
    |> Enum.join(" \\\n  ")
  end

  defp systemd_command(env) do
    """
    [Unit]
    Description=Firezone Gateway
    After=network.target
    Documentation=https://www.firezone.dev/kb

    [Service]
    Type=simple
    ExecStartPre=/bin/sh -c 'id -u firezone &>/dev/null || useradd -r -s /bin/false firezone'
    #{Enum.map_join(env, "\n", fn {key, value} -> "Environment=\"#{key}=#{value}\"" end)}
    ExecStartPre=/bin/sh -c 'set -xe; \\
      remote_version=$(curl -Ls \\
        -H "Accept: application/vnd.github+json" \\
        -H "X-GitHub-Api-Version: 2022-11-28" \\
        https://api.github.com/repos/firezone/firezone/releases/latest | \\
        grep "\\"tag_name\\": " | sed "s/.*\\"tag_name\\": \\"\\\\([^\\\\\\"]*\\\\).*/\\\\1/"); \\
      if [ -e /usr/local/bin/firezone-gateway ]; then \\
        current_version=$(/usr/local/bin/firezone-gateway --version | awk '"'"'{print $NF}'"'"'); \\
      else \\
        current_version=""; \\
      fi; \\
      if [ ! "$current_version" = "${remote_version:-latest}" ]; then \\
        echo "There is a new version of Firezone Gateway, downloading: ${remote_version:-latest}"; \\
        arch=$(uname -m); \\
        case $arch in \\
          aarch64) \\
            bin_url="https://github.com/firezone/firezone/releases/download/latest/gateway-arm64" ;; \\
          armv7l) \\
            bin_url="https://github.com/firezone/firezone/releases/download/latest/gateway-arm" ;; \\
          x86_64) \\
            bin_url="https://github.com/firezone/firezone/releases/download/latest/gateway-x64" ;; \\
          *) \\
            echo "Unsupported architecture"; \\
            exit 1 ;; \\
        esac; \\
        wget -O /usr/local/bin/firezone-gateway $bin_url; \\
        chmod +x /usr/local/bin/firezone-gateway; \\
      fi \\
    '
    ExecStartPre=/bin/sh -c 'mkdir -p /etc/firezone'
    ExecStartPre=/bin/sh -c 'chown firezone:firezone /etc/firezone'
    ExecStartPre=/bin/sh -c 'chmod 0755 /etc/firezone'
    ExecStartPre=/bin/sh -c 'chmod +x /usr/local/bin/firezone-gateway'
    AmbientCapabilities=CAP_NET_ADMIN
    PrivateTmp=true
    ProtectSystem=full
    ReadWritePaths=/etc/firezone
    NoNewPrivileges=true
    TimeoutStartSec=15s
    TimeoutStopSec=15s
    ExecStart=/bin/sh -c 'FIREZONE_NAME=$(hostname); sudo -u firezone -g firezone /usr/local/bin/firezone-gateway'
    Restart=always
    RestartSec=3

    [Install]
    WantedBy=multi-user.target
    """
  end

  def handle_event("tab_selected", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_tab: id)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "gateway_groups:" <> _group_id}, socket) do
    {:noreply, assign(socket, connected?: true)}
  end
end
