defmodule Web.GatewaysLive.New do
  use Web, :live_view

  def render(assigns) do
    ~H"""
    <.breadcrumbs home_path={~p"/#{@account}/dashboard"}>
      <.breadcrumb path={~p"/#{@account}/gateways"}>Gateways</.breadcrumb>
      <.breadcrumb path={~p"/#{@account}/gateways/new"}>Add Gateway</.breadcrumb>
    </.breadcrumbs>

    <.header>
      <:title>
        Add a new Gateway
      </:title>
    </.header>

    <section class="bg-white dark:bg-gray-900">
      <div class="py-8 px-4 mx-auto max-w-2xl lg:py-16">
        <h2 class="mb-4 text-xl font-bold text-gray-900 dark:text-white">Gateway details</h2>
        <form action="#">
          <div class="grid gap-4 sm:grid-cols-1 sm:gap-6">
            <div>
              <.label for="gateway-name">
                Name
              </.label>
              <input
                type="text"
                name="gateway-name"
                id="gateway-name"
                class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-primary-600 focus:border-primary-600 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600 dark:placeholder-gray-400 dark:text-white dark:focus:ring-primary-500 dark:focus:border-primary-500"
                required=""
              />
            </div>
            <div>
              <.label>
                Select a deployment method
              </.label>
            </div>
            <.tabs id="deployment-instructions">
              <:tab id="docker-instructions" label="Docker">
                <.code_block>
                  docker run -d \
                  --name=zigbee2mqtt \
                  --restart=always \
                  -v /opt/zigbee2mqtt/data:/app/data \
                  -v /run/udev:/run/udev:ro \
                  --device=/dev/ttyACM0 \
                  --net=host \
                  koenkk/zigbee2mqtt
                </.code_block>
              </:tab>
              <:tab id="systemd-instructions" label="Systemd">
                <.code_block>
                  [Unit]
                  Description=zigbee2mqtt
                  After=network.target

                  [Service]
                  ExecStart=/usr/bin/npm start
                  WorkingDirectory=/opt/zigbee2mqtt
                  StandardOutput=inherit
                  StandardError=inherit
                  Restart=always
                  User=pi
                </.code_block>
              </:tab>
            </.tabs>
          </div>

          <div id="gateway-submit-button" class="hidden">
            <!-- TODO: Display submit button when Gateway connection is detected -->
            <.submit_button>
              Create
            </.submit_button>
          </div>
          <div class="mt-4">
            <.p>
              Waiting for gateway connection...
            </.p>
          </div>
        </form>
      </div>
    </section>
    """
  end
end
