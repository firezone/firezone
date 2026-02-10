defmodule Portal.Channels do
  @moduledoc """
  Targeted message delivery to client and gateway channel processes using `:pg` process groups.

  Replaces the previous `PubSub.Account.broadcast` pattern which sent messages to every
  channel in an account. Instead, processes register under their specific ID and messages
  are sent directly to the registered processes.

  `:pg` works natively across distributed Erlang clusters, auto-deregisters dead processes,
  and handles netsplits by removing unreachable members from the local view.
  """

  @doc """
  Registers the calling process as a client channel for the given client ID.
  """
  def register_client(client_id) do
    :ok = :pg.join(group(:client, client_id), self())
  end

  @doc """
  Registers the calling process as a gateway channel for the given gateway ID.
  """
  def register_gateway(gateway_id) do
    :ok = :pg.join(group(:gateway, gateway_id), self())
  end

  @doc """
  Sends a message to all processes registered for the given client ID.

  Returns `:ok` if at least one process is registered, `{:error, :not_found}` otherwise.
  """
  def send_to_client(client_id, message) do
    send_to_group(group(:client, client_id), message)
  end

  @doc """
  Sends a message to all processes registered for the given gateway ID.

  Returns `:ok` if at least one process is registered, `{:error, :not_found}` otherwise.
  """
  def send_to_gateway(gateway_id, message) do
    send_to_group(group(:gateway, gateway_id), message)
  end

  @doc """
  Tells a gateway to reject access for a client to a resource.

  This is the public API for triggering reject_access from outside the channel system
  (e.g. integration tests, admin actions).
  """
  def reject_access(gateway_id, client_id, resource_id) do
    send_to_gateway(gateway_id, {:reject_access, client_id, resource_id})
  end

  defp send_to_group(group, message) do
    case :pg.get_members(group) do
      [] ->
        {:error, :not_found}

      pids ->
        Enum.each(pids, &send(&1, message))
        :ok
    end
  end

  defp group(type, id), do: {__MODULE__, type, id}
end
