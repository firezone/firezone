defmodule FzHttpWeb.Gateway.Channel do
  use FzHttpWeb, :channel

  @impl Phoenix.Channel
  def join("gateway:all", _payload, socket) do
    # XXX: Every gateway is expected to join here 
    {:ok, socket}
  end

  @impl Phoenix.Channel
  def join("gateway:" <> id, _, socket) do
    # XXX: Here we check for Guardian.Phoenix.Socket.current_claims to check if the gateway has access to the channel
    dbg(id)

    send(self(), :after_join)
    {:ok, socket}
  end

  @impl Phoenix.Channel
  def handle_info(:after_join, socket) do
    push(socket, "init", %{
      init: %{
        default_action: "deny",
        interface: %{
          address: ["100.64.11.22/10"],
          mtu: 1280
        },
        peers: [
          %{
            allowed_ips: [
              "100.64.11.22/32"
            ],
            public_key: "AxVaJsPC1FSrOM5RpEXg4umTKMxkHkgMy1fl7t1xyyw=",
            preshared_key: "LZBIpoLNCkIe56cPM+5pY/hP2pu7SGARvQZEThmuPYM=",
            user_uuid: "3118158c-29cb-47d6-adbf-5edd15f1af17"
          }
        ]
      }
    })

    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def handle_in("stats", stats, socket) do
    dbg(stats)
    {:noreply, socket}
  end
end
