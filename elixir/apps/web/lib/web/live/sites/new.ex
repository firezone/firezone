defmodule Web.Sites.New do
  use Web, :live_view
  alias Domain.Gateways

  def mount(_params, _session, socket) do
    changeset = Gateways.new_group()
    {:ok, assign(socket, form: to_form(changeset), group: nil)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/sites"}>Sites</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/sites/new"}>Add</.breadcrumb>
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
          <.form :if={is_nil(@group)} for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input
                  label="Name Prefix"
                  field={@form[:name_prefix]}
                  placeholder="Name of this Site"
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
                  [Unit]
                  Description=Firezone Gateway
                  After=network.target

                  [Service]
                  Type=simple
                  Environment="FIREZONE_TOKEN=<%= Gateways.encode_token!(hd(@group.tokens)) %>"
                  Environment="FIREZONE_VERSION=1.20231001.0"
                  Environment="FIREZONE_HOSTNAME=`hostname`"
                  Environment="FIREZONE_ENABLE_MASQUERADE=1"
                  ExecStartPre=/bin/sh -c ' \
                    if [ -e /usr/local/bin/firezone-gateway ]; then \
                      current_version=$(/usr/local/bin/firezone-gateway --version 2>&1 | awk "{print $NF}"); \
                    else \
                      current_version=""; \
                    fi; \
                    if [ ! "$$current_version" = "${FIREZONE_VERSION}" ]; then \
                      arch=$(uname -m); \
                      case $$arch in \
                        aarch64) \
                          bin_url="https://github.com/firezone/firezone/releases/download/${FIREZONE_VERSION}/gateway-aarch64-unknown-linux-musl-${FIREZONE_VERSION}" ;; \
                        armv7l) \
                          bin_url="https://github.com/firezone/firezone/releases/download/${FIREZONE_VERSION}/gateway-armv7-unknown-linux-musleabihf-${FIREZONE_VERSION}" ;; \
                        x86_64) \
                          bin_url="https://github.com/firezone/firezone/releases/download/${FIREZONE_VERSION}/gateway-x86_64-unknown-linux-musl-${FIREZONE_VERSION}" ;; \
                        *) \
                          echo "Unsupported architecture"; \
                          exit 1 ;; \
                      esac; \
                      wget -O /usr/local/bin/firezone-gateway $$bin_url; \
                    fi \
                  '
                  ExecStartPre=/usr/bin/chmod +x /usr/local/bin/firezone-gateway
                  ExecStart=/usr/local/bin/firezone-gateway
                  Restart=always
                  RestartSec=3

                  [Install]
                  WantedBy=multi-user.target
                </.code_block>
              </:tab>
            </.tabs>

            <div class="mt-4 animate-pulse">
              Waiting for gateway connection...
            </div>
          </div>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("change", %{"group" => attrs}, socket) do
    changeset =
      Gateways.new_group(attrs)
      |> Map.put(:action, :insert)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit", %{"group" => attrs}, socket) do
    attrs = Map.put(attrs, "tokens", [%{}])

    with {:ok, group} <-
           Gateways.create_group(attrs, socket.assigns.subject) do
      :ok = Gateways.subscribe_for_gateways_presence_in_group(group)
      {:noreply, assign(socket, group: group)}
    else
      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{topic: "gateway_groups:" <> _account_id}, socket) do
    socket =
      redirect(socket, to: ~p"/#{socket.assigns.account}/sites/#{socket.assigns.group}")

    {:noreply, socket}
  end
end
