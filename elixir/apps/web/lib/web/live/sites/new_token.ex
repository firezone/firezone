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

          token = encode_group_token(group)
          {group, env(token)}
        else
          {group, nil}
        end

      {:ok, assign(socket, group: group, env: env)}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}"}>
        <%= @group.name_prefix %>
      </.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/#{@group}/new_token"}>Deploy</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title :if={is_nil(@group)}>
        Add a new Site
      </:title>
      <:title :if={not is_nil(@group)}>
        Deploy your Gateway
      </:title>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <div class="text-xl mb-2">
            Select deployment method:
          </div>
          <.tabs :if={@env} id="deployment-instructions" phx-update="ignore">
            <:tab id="docker-instructions" label="Docker">
              <p class="pl-4 mb-2">
                Copy-paste this command to your server:
              </p>

              <.code_block id="code-sample-docker" class="w-full rounded-b" phx-no-format><%= docker_command(@env) %></.code_block>
            </:tab>
            <:tab id="systemd-instructions" label="Systemd">
              <p class="pl-4 mb-2">
                1. Create a systemd unit file with the following content:
              </p>

              <.code_block id="code-sample-systemd" class="w-full" phx-no-format>sudo nano /etc/systemd/system/firezone-gateway.service</.code_block>

              <p class="pl-4 mb-2 mt-4">
                2. Copy-paste the following content into the file:
              </p>

              <.code_block id="code-sample-systemd" class="w-full rounded-b" phx-no-format><%= systemd_command(@env) %></.code_block>

              <p class="pl-4 mb-2 mt-4">
                3. Save by pressing <kbd>Ctrl</kbd>+<kbd>X</kbd>, then <kbd>Y</kbd>, then <kbd>Enter</kbd>.
              </p>

              <p class="pl-4 mb-2 mt-4">
                4. Reload systemd configuration:
              </p>

              <.code_block id="code-sample-systemd" class="w-full" phx-no-format>sudo systemctl daemon-reload</.code_block>

              <p class="pl-4 mb-2 mt-4">
                5. Start the service:
              </p>

              <.code_block id="code-sample-systemd" class="w-full" phx-no-format>sudo systemctl start firezone-gateway</.code_block>

              <p class="pl-4 mb-2 mt-4">
                6. Enable the service to start on boot:
              </p>

              <.code_block id="code-sample-systemd" class="w-full" phx-no-format>sudo systemctl enable firezone-gateway</.code_block>

              <p class="pl-4 mb-2 mt-4">
                7. Check the status of the service:
              </p>

              <.code_block id="code-sample-systemd" class="w-full rounded-b" phx-no-format>sudo systemctl status firezone-gateway</.code_block>
            </:tab>
          </.tabs>

          <div :if={@env} class="mt-4 animate-pulse text-center">
            Waiting for gateway connection...
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
      "--sysctl net.ipv4.ip_forward=1",
      "--sysctl net.ipv4.conf.all.src_valid_mark=1",
      "--sysctl net.ipv6.conf.all.disable_ipv6=0",
      "--sysctl net.ipv6.conf.all.forwarding=1",
      "--sysctl net.ipv6.conf.default.forwarding=1",
      "--device=\"/dev/net/tun:/dev/net/tun\"",
      Enum.map(env, fn {key, value} -> "--env #{key}=\"#{value}\"" end),
      "--env FIREZONE_HOSTNAME=$(hostname)",
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

    [Service]
    Type=simple
    #{Enum.map_join(env, "\n", fn {key, value} -> "Environment=\"#{key}=#{value}\"" end)}
    ExecStartPre=/bin/sh -c ' \\
      remote_version=$(curl -Ls \\
        -H "Accept: application/vnd.github+json" \\
        -H "X-GitHub-Api-Version: 2022-11-28" \\
        https://api.github.com/repos/firezone/firezone/releases/latest | grep -oP '"'"'(?<="tag_name": ")[^"]*'"'"'); \\
      if [ -e /usr/local/bin/firezone-gateway ]; then \\
        current_version=$(/usr/local/bin/firezone-gateway --version | awk '"'"'{print $NF}'"'"'); \\
      else \\
        current_version=""; \\
      fi; \\
      if [ ! "$current_version" = "$remote_version" ]; then \\
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
    ExecStartPre=/usr/bin/chmod +x /usr/local/bin/firezone-gateway
    ExecStart=FIREZONE_HOSTNAME=$(hostname) /usr/local/bin/firezone-gateway
    Restart=always
    RestartSec=3

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp encode_group_token(group) do
    Gateways.encode_token!(hd(group.tokens))
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "gateway_groups:" <> _account_id}, socket) do
    socket =
      redirect(socket, to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.group}")

    {:noreply, socket}
  end
end
