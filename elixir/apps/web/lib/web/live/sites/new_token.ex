defmodule Web.Sites.NewToken do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <- Gateways.fetch_group_by_id(id, socket.assigns.subject) do
      {:ok, group} =
        Gateways.update_group(%{group | tokens: []}, %{tokens: [%{}]}, socket.assigns.subject)

      {:ok, assign(socket, group: group)}
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
          <.tabs id="deployment-instructions">
            <:tab id="docker-instructions" label="Docker">
              <.code_block id="code-sample-docker" class="w-full rounded-b-lg" phx-no-format>
                  docker run -d \<br />
                  &nbsp; --restart=unless-stopped \<br />
                  &nbsp; --pull=always \<br />
                  &nbsp; --health-cmd="ip link | grep tun-firezone" \<br />
                  &nbsp; --name=firezone-gateway \<br />
                  &nbsp; --cap-add=NET_ADMIN \<br />
                  &nbsp; --sysctl net.ipv4.ip_forward=1 \<br />
                  &nbsp; --sysctl net.ipv4.conf.all.src_valid_mark=1 \<br />
                  &nbsp; --sysctl net.ipv6.conf.all.disable_ipv6=0 \<br />
                  &nbsp; --sysctl net.ipv6.conf.all.forwarding=1 \<br />
                  &nbsp; --sysctl net.ipv6.conf.default.forwarding=1 \<br />
                  &nbsp; --device="/dev/net/tun:/dev/net/tun" \<br />
                  &nbsp; --env FIREZONE_ID="<%= Ecto.UUID.generate() %>" \<br />
                  &nbsp; --env FIREZONE_TOKEN="<%= Gateways.encode_token!(hd(@group.tokens)) %>" \<br />
                  &nbsp; --env FIREZONE_ENABLE_MASQUERADE=1 \<br />
                  &nbsp; --env FIREZONE_HOSTNAME="`hostname`" \<br />
                  &nbsp; --env RUST_LOG="warn" \<br />
                  &nbsp; ghcr.io/firezone/gateway:${FIREZONE_VERSION:-1}
                </.code_block>
            </:tab>
            <:tab id="systemd-instructions" label="Systemd">
              <.code_block id="code-sample-systemd" class="w-full rounded-b-lg" phx-no-format>
                  [Unit]<br />
                  Description=Firezone Gateway<br />
                  After=network.target<br />
                  <br />
                  [Service]<br />
                  Type=simple<br />
                  Environment="FIREZONE_TOKEN=<%= Gateways.encode_token!(hd(@group.tokens)) %>"<br />
                  Environment="FIREZONE_VERSION=1.20231001.0"<br />
                  Environment="FIREZONE_HOSTNAME=`hostname`"<br />
                  Environment="FIREZONE_ENABLE_MASQUERADE=1"<br />
                  ExecStartPre=/bin/sh -c ' \<br />
                    if [ -e /usr/local/bin/firezone-gateway ]; then \<br />
                      current_version=$(/usr/local/bin/firezone-gateway --version 2>&1 | awk "{print $NF}"); \<br />
                    else \<br />
                      current_version=""; \<br />
                    fi; \<br />
                    if [ ! "$$current_version" = "${FIREZONE_VERSION}" ]; then \<br />
                      arch=$(uname -m); \<br />
                      case $$arch in \<br />
                        aarch64) \<br />
                          bin_url="https://github.com/firezone/firezone/releases/download/${FIREZONE_VERSION}/gateway-aarch64-unknown-linux-musl-${FIREZONE_VERSION}" ;; \<br />
                        armv7l) \<br />
                          bin_url="https://github.com/firezone/firezone/releases/download/${FIREZONE_VERSION}/gateway-armv7-unknown-linux-musleabihf-${FIREZONE_VERSION}" ;; \<br />
                        x86_64) \<br />
                          bin_url="https://github.com/firezone/firezone/releases/download/${FIREZONE_VERSION}/gateway-x86_64-unknown-linux-musl-${FIREZONE_VERSION}" ;; \<br />
                        *) \<br />
                          echo "Unsupported architecture"; \<br />
                          exit 1 ;; \<br />
                      esac; \<br />
                      wget -O /usr/local/bin/firezone-gateway $$bin_url; \<br />
                    fi \<br />
                  '<br />
                  ExecStartPre=/usr/bin/chmod +x /usr/local/bin/firezone-gateway<br />
                  ExecStart=/usr/local/bin/firezone-gateway<br />
                  Restart=always<br />
                  RestartSec=3<br />
                  <br />
                  [Install]<br />
                  WantedBy=multi-user.target<br />
                </.code_block>
            </:tab>
          </.tabs>

          <div class="mt-4 animate-pulse">
            Waiting for gateway connection...
          </div>
        </div>
      </:content>
    </.section>
    """
  end
end
