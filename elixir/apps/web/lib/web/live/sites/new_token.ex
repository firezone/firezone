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
              <.code_block id="code-sample-docker" class="w-full rounded-b" phx-no-format><%= docker_command(@env) %></.code_block>
            </:tab>
            <:tab id="systemd-instructions" label="Systemd">
              <.code_block id="code-sample-systemd" class="w-full rounded-b" phx-no-format><%= systemd_command(@env) %></.code_block>
            </:tab>
          </.tabs>

          <div :if={@env} class="mt-4 animate-pulse">
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
        # if api_url = false do
        {"FIREZONE_API_URL", api_url}
      end

    [
      {"FIREZONE_ID", Ecto.UUID.generate()},
      {"FIREZONE_TOKEN", token},
      {"FIREZONE_ENABLE_MASQUERADE", "1"},
      {"FIREZONE_HOSTNAME", "$(hostname)"},
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
    #{Enum.map(env, fn {key, value} -> "Environment=\"#{key}=#{value}\"" end) |> Enum.join("\n")}
    ExecStartPre=/bin/sh -c ' \\
      if [ -e /usr/local/bin/firezone-gateway ]; then \\
        current_version=$(/usr/local/bin/firezone-gateway --version 2>&1 | awk "{print $NF}"); \\
      else \\
        current_version=""; \\
      fi; \\
      if [ ! "$$current_version" = "${FIREZONE_VERSION}" ]; then \\
        arch=$(uname -m); \\
        case $$arch in \\
          aarch64) \\
            bin_url="https://github.com/firezone/firezone/releases/download/${FIREZONE_VERSION}/gateway-arm64" ;; \\
          armv7l) \\
            bin_url="https://github.com/firezone/firezone/releases/download/${FIREZONE_VERSION}/gateway-arm" ;; \\
          x86_64) \\
            bin_url="https://github.com/firezone/firezone/releases/download/${FIREZONE_VERSION}/gateway-x64" ;; \\
          *) \\
            echo "Unsupported architecture"; \\
            exit 1 ;; \\
        esac; \\
        wget -O /usr/local/bin/firezone-gateway $$bin_url; \\
      fi \\
    '
    ExecStartPre=/usr/bin/chmod +x /usr/local/bin/firezone-gateway
    ExecStart=/usr/local/bin/firezone-gateway
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
