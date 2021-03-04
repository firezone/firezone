defmodule FgHttpWeb.Events do
  @moduledoc """
  Handles interfacing with other processes in the system
  """

  import FgHttpWeb.EventHelpers

  def create_device_sync do
    case vpn_pid() do
      {:ok, pid} ->
        send(pid, {:create_device, self()})

        receive do
          {:device_created, privkey, pubkey, server_pubkey, psk} ->
            {:ok,
             %{
               private_key: privkey,
               public_key: pubkey,
               server_public_key: server_pubkey,
               preshared_key: psk
             }}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end
end
