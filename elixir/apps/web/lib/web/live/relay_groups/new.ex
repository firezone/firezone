defmodule Web.RelayGroups.New do
  use Web, :live_view
  alias Domain.Relays

  def mount(_params, _session, socket) do
    changeset = Relays.new_group()
    {:ok, assign(socket, form: to_form(changeset), group: nil)}
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
      {:noreply, assign(socket, group: group)}
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

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/relay_groups"}>Relay Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/relay_groups/new"}>Add</.breadcrumb>
    </.breadcrumbs>

    <.header>
      <:title :if={is_nil(@group)}>
        Add a new Relay Instance Group
      </:title>
      <:title :if={not is_nil(@group)}>
        Deploy your Relay Instance
      </:title>
    </.header>

    <section class="bg-white dark:bg-gray-900">
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
          <.tabs id="deployment-instructions">
            <:tab id="docker-instructions" label="Docker">
              <.code_block id="code-sample-docker" class="w-full rounded-b-lg" phx-no-format>
                  docker run -d \<br />
                  &nbsp; --name=firezone-relay-0 \<br />
                  &nbsp; --restart=always \<br />
                  &nbsp; -v /dev/net/tun:/dev/net/tun \<br />
                  &nbsp; -e PORTAL_TOKEN=<%= Relays.encode_token!(hd(@group.tokens)) %> \<br />
                  &nbsp; us-east1-docker.pkg.dev/firezone/firezone/relay:stable
                </.code_block>
            </:tab>
            <:tab id="systemd-instructions" label="Systemd">
              <.code_block id="code-sample-systemd" class="w-full rounded-b-lg" phx-no-format>
                  [Unit]<br />
                  Description=zigbee2mqtt<br />
                  After=network.target<br />
                  <br />
                  [Service]<br />
                  ExecStart=/usr/bin/npm start<br />
                  WorkingDirectory=/opt/zigbee2mqtt<br />
                  StandardOutput=inherit<br />
                  StandardError=inherit<br />
                  Restart=always<br />
                  User=pi
                </.code_block>
            </:tab>
          </.tabs>

          <div class="mt-4 animate-pulse">
            Waiting for relay connection...
          </div>
        </div>
      </div>
    </section>
    """
  end
end
