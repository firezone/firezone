defmodule Domain.Relays.Presence.Debouncer do
  require Logger
  alias Domain.Relays

  @moduledoc """
  Encapsulates the logic for debouncing relay presence leave events to prevent
  sending spurious disconnects to clients/gateways when a relay experiences
  transient disconnections to the portal.
  """

  def cache_stamp_secrets(socket, relays) do
    stamp_secrets = Map.get(socket.assigns, :stamp_secrets, %{})

    stamp_secrets =
      Enum.reduce(relays, stamp_secrets, fn relay, acc ->
        Map.put(acc, relay.id, relay.stamp_secret)
      end)

    Phoenix.Socket.assign(socket, :stamp_secrets, stamp_secrets)
  end

  # Removes reconnected relays from pending leaves:
  # - If the stamp secret hasn't changed, we need to cancel the pending leave
  # - If it has, we need to disconnect from the relay immediately
  def cancel_leaves_or_disconnect_immediately(socket, joined_ids, account_id) do
    {:ok, connected_relays} =
      Relays.all_connected_relays_for_account(account_id)

    joined_stamp_secrets =
      connected_relays
      |> Enum.filter(fn relay -> relay.id in joined_ids end)
      |> Enum.reduce(%{}, fn relay, acc -> Map.put(acc, relay.id, relay.stamp_secret) end)

    pending_leaves = Map.get(socket.assigns, :pending_leaves, %{})

    # Immediately disconnect from relays where stamp secret has changed
    disconnected_ids =
      Enum.reduce(pending_leaves, [], fn {relay_id, stamp_secret}, acc ->
        if Map.get(joined_stamp_secrets, relay_id) != stamp_secret do
          [relay_id | acc]
        else
          acc
        end
      end)

    # Remove any reconnected relays from pending leaves
    pending_leaves =
      pending_leaves
      |> Map.reject(fn {relay_id, _stamp_secret} ->
        relay_id in joined_ids
      end)

    socket = Phoenix.Socket.assign(socket, :pending_leaves, pending_leaves)

    {socket, disconnected_ids}
  end

  def queue_leave(pid, socket, relay_id, payload) do
    stamp_secrets = Map.get(socket.assigns, :stamp_secrets, %{})
    stamp_secret = Map.get(stamp_secrets, relay_id)
    Process.send_after(pid, {:push_leave, relay_id, stamp_secret, payload}, timeout())
    pending_leaves = Map.get(socket.assigns, :pending_leaves, %{})

    Phoenix.Socket.assign(
      socket,
      :pending_leaves,
      Map.put(pending_leaves, relay_id, stamp_secret)
    )
  end

  def handle_leave(socket, relay_id, stamp_secret, payload, push_fn) do
    pending_leaves = Map.get(socket.assigns, :pending_leaves, %{})

    if Map.get(pending_leaves, relay_id) == stamp_secret do
      push_fn.(socket, "relays_presence", payload)

      Phoenix.Socket.assign(socket, :pending_leaves, Map.delete(pending_leaves, relay_id))
    else
      socket
    end
  end

  def timeout do
    Application.fetch_env!(:api, :relays_presence_debounce_timeout)
  end
end
