defmodule Web.Sites.NewToken do
  use Web, :live_view
  alias Domain.Gateways

  def mount(%{"id" => id}, _session, socket) do
    with {:ok, group} <-
           Gateways.fetch_group_by_id(id, socket.assigns.subject,
             filter: [
               deleted?: false
             ]
           ) do
      {group, token, env} =
        if connected?(socket) do
          {:ok, token, encoded_token} = Gateways.create_token(group, %{}, socket.assigns.subject)
          :ok = Gateways.subscribe_to_gateways_presence_in_group(group)
          {group, token, env(encoded_token)}
        else
          {group, nil, nil}
        end

      {:ok,
       assign(socket,
         page_title: "New Site Gateway",
         group: group,
         token: token,
         env: env,
         connected?: false
       )}
    else
      {:error, _reason} -> raise Web.LiveErrors.NotFoundError
    end
  end

  def handle_params(params, uri, socket) do
    {:noreply,
     assign(socket,
       uri: uri,
       selected_tab: Map.get(params, "method", "systemd-instructions")
     )}
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
        Gateways require egress connectivity to the control plane API and relay servers.
        <strong>No ingress firewall rules</strong>
        are required or recommended. See our
        <.website_link href="/kb/deploy/gateways#firewall-ports">
          deploy guide
        </.website_link>
        for more information.
      </:help>
      <:help>
        Read the
        <.website_link href="/kb/deploy/gateways">
          gateway deployment guide
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
              id="systemd-instructions"
              label="systemd"
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

              <p class="p-4">
                <strong>Important:</strong>
                You'll need to make sure that the <code>iptables</code>
                and <code>ip6tables</code>
                commands are available on your system.
              </p>
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
            <:tab
              id="binary-instructions"
              label="Manually"
              phx_click="tab_selected"
              selected={@selected_tab == "binary-instructions"}
            >
              <p class="p-4">
                <.link
                  href="https://www.github.com/firezone/firezone/releases?utm_source=deploy_gateway"
                  target="_blank"
                  class={link_style()}
                >
                  Download the latest binary
                </.link>
                from GitHub releases to your server and make sure the following environment variables are set:
              </p>

              <.code_block
                id="code-sample-binary1"
                class="w-full text-xs whitespace-pre-line"
                phx-no-format
                phx-update="ignore"
              ><%= manual_command(@env) %></.code_block>

              <p class="p-4">
                <strong>Important:</strong>
                You'll need to make sure that the <code>iptables</code>
                and <code>ip6tables</code>
                commands are available on your system.
              </p>
            </:tab>
          </.tabs>

          <div id="connection-status" class="flex justify-between items-center">
            <p class="text-sm">
              Gateway not connecting? See our
              <.website_link href="/kb/administer/troubleshooting#gateway-not-connecting">
                gateway troubleshooting guide
              </.website_link>.
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

  defp env(encoded_token) do
    api_url_override =
      if api_url = Domain.Config.get_env(:web, :api_url_override) do
        {"FIREZONE_API_URL", api_url}
      end

    [
      {"FIREZONE_TOKEN", encoded_token},
      api_url_override
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
      "#{Domain.Config.fetch_env!(:domain, :docker_registry)}/gateway:1"
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

  defp manual_command(env) do
    """
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
          topic: "presences:group_gateways:" <> _group_id,
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
          gateway = Gateways.fetch_gateway_by_id!(id)
          socket.assigns.token.id == gateway.last_used_token_id
        end)

      {:noreply, assign(socket, connected?: connected?)}
    end
  end
end
