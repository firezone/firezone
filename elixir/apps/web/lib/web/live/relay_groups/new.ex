defmodule Web.RelayGroups.New do
  use Web, :live_view
  alias Domain.Relays

  def mount(_params, _session, socket) do
    changeset = Relays.new_group()
    {:ok, assign(socket, form: to_form(changeset), group: nil)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/relay_groups"}>Relay Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/new"}>Add</.breadcrumb>
    </.breadcrumbs>
    <.section>
      <:title :if={is_nil(@group)}>
        Add a new Relay Instance Group
      </:title>
      <:title :if={not is_nil(@group)}>
        Deploy your Relay Instance
      </:title>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <.form :if={is_nil(@group)} for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input
                  label="Name Prefix"
                  field={@form[:name]}
                  placeholder="Name of this Relay Instance Group"
                  required
                />
              </div>
            </div>

            <.submit_button>
              Save
            </.submit_button>
          </.form>

          <div :if={not is_nil(@group)}>
            <div class="text-xl mb-2">
              Select deployment method:
            </div>
            <.tabs id="deployment-instructions" phx-update="ignore">
              <:tab id="docker-instructions" label="Docker">
                <p class="pl-4 mb-2">
                  Copy-paste this command to your server and replace <code>PUBLIC_IP4_ADDR</code>
                  and <code>PUBLIC_IP6_ADDR</code>
                  with your public IP addresses:
                </p>

                <.code_block id="code-sample-docker" class="w-full rounded-b" phx-no-format><%= docker_command(@env) %></.code_block>
              </:tab>
              <:tab id="systemd-instructions" label="Systemd">
                <p class="pl-4 mb-2">
                  1. Create a systemd unit file with the following content:
                </p>

                <.code_block id="code-sample-systemd" class="w-full" phx-no-format>sudo nano /etc/systemd/system/firezone-relay.service</.code_block>

                <p class="pl-4 mb-2 mt-4">
                  2. Copy-paste the following content into the file and replace
                  <code>PUBLIC_IP4_ADDR</code>
                  and <code>PUBLIC_IP6_ADDR</code>
                  with your public IP addresses::
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

                <.code_block id="code-sample-systemd" class="w-full" phx-no-format>sudo systemctl start firezone-relay</.code_block>

                <p class="pl-4 mb-2 mt-4">
                  6. Enable the service to start on boot:
                </p>

                <.code_block id="code-sample-systemd" class="w-full" phx-no-format>sudo systemctl enable firezone-relay</.code_block>

                <p class="pl-4 mb-2 mt-4">
                  7. Check the status of the service:
                </p>

                <.code_block id="code-sample-systemd" class="w-full rounded-b" phx-no-format>sudo systemctl status firezone-relay</.code_block>
              </:tab>
            </.tabs>

            <div class="mt-4 animate-pulse text-center">
              Waiting for relay connection...
            </div>
          </div>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"group" => attrs}, socket) do
    changeset =
      Relays.new_group(attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"group" => attrs}, socket) do
    attrs = Map.put(attrs, "tokens", [%{}])

    with {:ok, group} <-
           Relays.create_group(attrs, socket.assigns.subject) do
      :ok = Relays.subscribe_for_relays_presence_in_group(group)
      token = encode_group_token(group)
      {:noreply, assign(socket, group: group, env: env(token))}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "relay_groups:" <> _account_id}, socket) do
    socket =
      push_redirect(socket,
        to: ~p"/#{socket.assigns.account}/relay_groups/#{socket.assigns.group}"
      )

    {:noreply, socket}
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
      {"PUBLIC_IP4_ADDR", "YOU_MUST_SET_THIS_VALUE"},
      {"PUBLIC_IP6_ADDR", "YOU_MUST_SET_THIS_VALUE"},
      api_url_override,
      {"RUST_LOG", "warn"},
      {"LOG_FORMAT", "google-cloud"}
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp docker_command(env) do
    [
      "docker run -d",
      "--restart=unless-stopped",
      "--pull=always",
      "--health-cmd=\"lsof -i UDP | grep firezone-relay\"",
      "--name=firezone-relay",
      "--cap-add=NET_ADMIN",
      "--sysctl net.ipv4.ip_forward=1",
      "--sysctl net.ipv4.conf.all.src_valid_mark=1",
      "--sysctl net.ipv6.conf.all.disable_ipv6=0",
      "--sysctl net.ipv6.conf.all.forwarding=1",
      "--sysctl net.ipv6.conf.default.forwarding=1",
      "--device=\"/dev/net/tun:/dev/net/tun\"",
      Enum.map(env, fn {key, value} -> "--env #{key}=\"#{value}\"" end),
      "--env FIREZONE_HOSTNAME=$(hostname)",
      "#{Domain.Config.fetch_env!(:domain, :docker_registry)}/relay:#{version()}"
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
      if [ -e /usr/local/bin/firezone-relay ]; then \\
        current_version=$(/usr/local/bin/firezone-relay --version | awk '"'"'{print $NF}'"'"'); \\
      else \\
        current_version=""; \\
      fi; \\
      if [ ! "$current_version" = "$remote_version" ]; then \\
        arch=$(uname -m); \\
        case $arch in \\
          aarch64) \\
            bin_url="https://github.com/firezone/firezone/releases/download/latest/relay-arm64" ;; \\
          armv7l) \\
            bin_url="https://github.com/firezone/firezone/releases/download/latest/relay-arm" ;; \\
          x86_64) \\
            bin_url="https://github.com/firezone/firezone/releases/download/latest/relay-x64" ;; \\
          *) \\
            echo "Unsupported architecture"; \\
            exit 1 ;; \\
        esac; \\
        wget -O /usr/local/bin/firezone-relay $bin_url; \\
        chmod +x /usr/local/bin/firezone-relay; \\
      fi \\
    '
    ExecStartPre=/usr/bin/chmod +x /usr/local/bin/firezone-relay
    ExecStart=FIREZONE_HOSTNAME=$(hostname) /usr/local/bin/firezone-relay
    Restart=always
    RestartSec=3

    [Install]
    WantedBy=multi-user.target
    """
  end

  defp encode_group_token(group) do
    Relays.encode_token!(hd(group.tokens))
  end
end
