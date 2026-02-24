defmodule Portal.Channels do
  @moduledoc """
  Targeted message delivery to client and gateway channel processes using `:pg` as a registry.

  Replaces the previous `PubSub.Account.broadcast` pattern which sent messages to every
  channel in an account. Instead, processes register under their specific ID and messages
  are delivered directly via `GenServer.call/2`.

  `:pg` works natively across distributed Erlang clusters, auto-deregisters dead processes,
  and handles netsplits by removing unreachable members from the local view.
  """

  @doc """
  Registers the calling process as a client channel for the given client ID.
  """
  def register_client(client_id) do
    :ok = :pg.join(pg_key(:client, client_id), self())
  end

  @doc """
  Registers the calling process as a gateway channel for the given gateway ID.
  """
  def register_gateway(gateway_id) do
    :ok = :pg.join(pg_key(:gateway, gateway_id), self())
  end

  @doc """
  Calls the registered client channel process with the given message.

  Returns `:ok` if the process handled the call, `{:error, :not_found}` if no process
  is registered or the process exits or times out.
  """
  def send_to_client(client_id, message) do
    call_channel(pg_key(:client, client_id), message)
  end

  @doc """
  Calls the registered gateway channel process with the given message.

  Returns `:ok` if the process handled the call, `{:error, :not_found}` if no process
  is registered or the process exits or times out.
  """
  def send_to_gateway(gateway_id, message) do
    call_channel(pg_key(:gateway, gateway_id), message)
  end

  @doc """
  Tells a gateway to reject access for a client to a resource.

  This is the public API for triggering reject_access from outside the channel system
  (e.g. integration tests, admin actions).
  """
  def reject_access(gateway_id, client_id, resource_id) do
    send_to_gateway(gateway_id, {:reject_access, client_id, resource_id})
  end

  defp call_channel(pg_key, message) do
    case :pg.get_members(pg_key) do
      [] ->
        {:error, :not_found}

      [pid] ->
        GenServer.call(pid, message)
        :ok
    end
  catch
    :exit, _ -> {:error, :not_found}
  end

  defp pg_key(type, id), do: {__MODULE__, type, id}
end
