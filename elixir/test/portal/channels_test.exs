defmodule Portal.ChannelsTest do
  use ExUnit.Case, async: true
  alias Portal.Channels

  for {type, register, deliver} <- [
        {:client, &Channels.register_client/1, &Channels.send_to_client/2},
        {:gateway, &Channels.register_gateway/1, &Channels.send_to_gateway/2}
      ] do
    @register register
    @deliver deliver

    test "delivers message to registered #{type} process" do
      id = Ecto.UUID.generate()
      spawn_call_receiver(fn -> @register.(id) end)
      assert :ok = @deliver.(id, :hello)
      assert_receive {:received, _pid, :hello}
    end

    test "returns {:error, :not_found} when no #{type} is registered" do
      assert {:error, :not_found} = @deliver.(Ecto.UUID.generate(), :hello)
    end
  end

  describe "process exit cleanup" do
    test "removes process from group when it exits" do
      client_id = Ecto.UUID.generate()
      parent = self()

      pid =
        spawn(fn ->
          Channels.register_client(client_id)
          send(parent, :registered)

          receive do
            {:"$gen_call", from, _message} ->
              GenServer.reply(from, :ok)
              receive do: (:stop -> :ok)
          end
        end)

      assert_receive :registered
      assert :ok = Channels.send_to_client(client_id, :ping)

      Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, _, :process, ^pid, :normal}

      Process.sleep(50)
      assert {:error, :not_found} = Channels.send_to_client(client_id, :ping)
    end
  end

  describe "reject_access/3" do
    test "sends reject_access message to the gateway" do
      gateway_id = Ecto.UUID.generate()
      client_id = Ecto.UUID.generate()
      resource_id = Ecto.UUID.generate()

      spawn_call_receiver(fn -> Channels.register_gateway(gateway_id) end)

      assert :ok = Channels.reject_access(gateway_id, client_id, resource_id)
      assert_receive {:received, _pid, {:reject_access, ^client_id, ^resource_id}}
    end

    test "returns {:error, :not_found} when gateway is not registered" do
      assert {:error, :not_found} = Channels.reject_access(Ecto.UUID.generate(), "c", "r")
    end
  end

  defp spawn_call_receiver(register_fn) do
    parent = self()

    pid =
      spawn(fn ->
        register_fn.()
        send(parent, {:registered, self()})
        call_receiver_loop(parent)
      end)

    assert_receive {:registered, ^pid}
    pid
  end

  defp call_receiver_loop(parent) do
    receive do
      {:"$gen_call", from, message} ->
        GenServer.reply(from, :ok)
        send(parent, {:received, self(), message})
        call_receiver_loop(parent)
    end
  end
end
