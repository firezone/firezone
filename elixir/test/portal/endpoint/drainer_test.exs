defmodule Portal.Endpoint.DrainerTest do
  use ExUnit.Case, async: true

  alias Phoenix.Channel.Server
  alias Portal.Endpoint.Drainer

  defmodule TestChannel do
    use Phoenix.Channel

    # Busy after the join, so that the drain message waits in the mailbox.
    def join(_topic, _payload, socket) do
      send(self(), :busy)
      {:ok, socket}
    end

    def handle_info(:busy, socket) do
      Process.sleep(200)
      {:noreply, socket}
    end
  end

  defmodule TestSocket do
    use Phoenix.Socket

    channel "drainer_test:*", TestChannel

    def connect(_params, socket, _connect_info), do: {:ok, socket}
    def id(_socket), do: nil
  end

  defmodule TestEndpoint do
    use Phoenix.Endpoint, otp_app: :portal

    socket "/socket", TestSocket, websocket: true, longpoll: false, drainer: false
  end

  import Phoenix.ChannelTest

  @endpoint TestEndpoint

  setup do
    start_supervised!(
      {TestEndpoint, pubsub_server: Portal.PubSub, secret_key_base: String.duplicate("a", 64)}
    )

    :ok
  end

  test "drains every channel and waits until they stop" do
    channels =
      for _ <- 1..3 do
        message = %Phoenix.Socket.Message{
          topic: "drainer_test:#{System.unique_integer([:positive])}",
          payload: %{},
          ref: "1"
        }

        # Phoenix.ChannelTest.join/3 starts channels outside the socket's pool supervisor.
        {:ok, _reply, channel} = Server.join(socket(TestSocket, nil, %{}), TestChannel, message, [])
        channel
      end

    start_supervised!({Drainer, endpoints: [TestEndpoint]})
    :ok = stop_supervised!(Drainer)

    for channel <- channels do
      refute Process.alive?(channel)
      assert_received :socket_drain
    end
  end

  test "does nothing when the endpoint is not running" do
    :ok = stop_supervised!(TestEndpoint)
    start_supervised!({Drainer, endpoints: [TestEndpoint]})

    assert :ok = stop_supervised!(Drainer)
  end
end
