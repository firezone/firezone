defmodule Web.GatewayGroups.New do
  use Web, :live_view
  alias Domain.Gateways

  def mount(_params, _session, socket) do
    changeset = Gateways.new_group()
    {:ok, assign(socket, form: to_form(changeset), group: nil)}
  end

  def render(assigns) do
    ~H"""
    <.breadcrumbs account={@account}>
      <.breadcrumb path={~p"/#{@account}/gateway_groups"}>Gateway Instance Groups</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateway_groups/new"}>Add</.breadcrumb>
    </.breadcrumbs>

    <.section>
      <:title :if={is_nil(@group)}>
        Add a new Gateway Instance Group
      </:title>
      <:title :if={not is_nil(@group)}>
        Deploy your Gateway Instance
      </:title>
      <:content>
        <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
          <.form :if={is_nil(@group)} for={@form} phx-change={:change} phx-submit={:submit}>
            <div class="grid gap-4 mb-4 sm:grid-cols-1 sm:gap-6 sm:mb-6">
              <div>
                <.input
                  label="Name Prefix"
                  field={@form[:name_prefix]}
                  placeholder="Name of this Gateway Instance Group"
                  required
                />
              </div>

              <div>
                <.input label="Tags" type="taglist" field={@form[:tags]} placeholder="Tag" />
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
                  &nbsp; --name=firezone-gateway-0 \<br />
                  &nbsp; --restart=always \<br />
                  &nbsp; -v /dev/net/tun:/dev/net/tun \<br />
                  &nbsp; -e FZ_SECRET=<%= Gateways.encode_token!(hd(@group.tokens)) %> \<br />
                  &nbsp; us-east1-docker.pkg.dev/firezone/firezone/gateway:stable
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
              Waiting for gateway connection...
            </div>
          </div>
        </div>
      </:content>
    </.section>
    """
  end

  def handle_event("delete:group[tags]", %{"index" => index}, socket) do
    changeset = socket.assigns.form.source
    values = Ecto.Changeset.fetch_field!(changeset, :tags) || []
    values = List.delete_at(values, String.to_integer(index))
    changeset = Ecto.Changeset.put_change(changeset, :tags, values)
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("add:group[tags]", _params, socket) do
    changeset = socket.assigns.form.source
    values = Ecto.Changeset.fetch_field!(changeset, :tags) || []
    changeset = Ecto.Changeset.put_change(changeset, :tags, values ++ [""])
    {:noreply, assign(socket, form: to_form(changeset))}
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
      redirect(socket, to: ~p"/#{socket.assigns.account}/gateway_groups/#{socket.assigns.group}")

    {:noreply, socket}
  end
end
