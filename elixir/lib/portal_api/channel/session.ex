defmodule PortalAPI.Channel.Session do
  @moduledoc """
  The lifecycle of a device's channel, shared by Clients and Gateways: how it ends, how it
  applies changes, and how it stays registered in `Portal.PG` and tracked in presence when
  those processes crash.
  """
  import Phoenix.Channel, only: [push: 3]
  import Phoenix.Socket, only: [assign: 3]

  alias Portal.{Changes.Change, PG, Presence}

  require Logger

  @doc """
  On an abnormal exit, drains the whole WebSocket instead of only letting the channel die.
  connlib ignores `phx_error` and keeps the transport, rejoining on it with the
  transport-scoped session_ref, whose earlier flush confirmation could cancel the new
  session's durability timer. A drain forces a full reconnect through `Socket.connect/3` and a
  new session_ref. Graceful stops already send `phx_close`.
  """
  @spec terminate(term(), Phoenix.Socket.t()) :: :ok
  def terminate(reason, socket) do
    if abnormal_exit?(reason) do
      send(socket.transport_pid, :socket_drain)
    end

    :ok
  end

  @doc """
  Tells the device its token expired, then closes. The push comes first so that the device
  does not reconnect at once.
  """
  @spec disconnect(Phoenix.Socket.t()) :: {:stop, :shutdown, Phoenix.Socket.t()}
  def disconnect(socket) do
    push(socket, "disconnect", %{reason: "token_expired"})
    close_transport(socket)
  end

  @doc """
  Stops the channel and its transport. Stopping the channel alone leaves the transport up, and
  a rejoin on it reuses the assigns from `Socket.connect/3` without checking them again.
  """
  @spec close_transport(Phoenix.Socket.t()) :: {:stop, :shutdown, Phoenix.Socket.t()}
  def close_transport(socket) do
    send(socket.transport_pid, :socket_drain)
    {:stop, :shutdown, socket}
  end

  @doc "Applies a change once: a change at or below the last applied LSN is a replay."
  @spec apply_change(Phoenix.Socket.t(), Change.t(), (Change.t(), Phoenix.Socket.t() -> result)) ::
          result
        when result: {:noreply, Phoenix.Socket.t()} | {:stop, term(), Phoenix.Socket.t()}
  def apply_change(socket, %Change{lsn: lsn} = change, handle_change) do
    if lsn > Map.get(socket.assigns, :last_lsn, 0) do
      case handle_change.(change, socket) do
        {:noreply, socket} -> {:noreply, assign(socket, :last_lsn, lsn)}
        result -> result
      end
    else
      {:noreply, socket}
    end
  end

  @doc """
  Monitors the `Portal.PG` scope. Returns `{:joined, socket, previous_pid}` when the channel
  must join its groups, with `previous_pid` nil on the first registration. While the scope is
  down, `:register` is sent again shortly.
  """
  @spec monitor_pg_scope(Phoenix.Socket.t()) ::
          {:joined, Phoenix.Socket.t(), pid() | nil} | {:noreply, Phoenix.Socket.t()}
  def monitor_pg_scope(socket) do
    current_pid = socket.assigns[:pg_scope_pid]

    case PG.scope_pid() do
      nil ->
        Logger.error("Portal.PG scope is not running, retrying registration shortly")
        Process.send_after(self(), :register, 50)
        {:noreply, socket}

      ^current_pid ->
        {:noreply, socket}

      new_pid ->
        Process.monitor(new_pid)
        {:joined, assign(socket, :pg_scope_pid, new_pid), current_pid}
    end
  end

  @doc """
  Tracks the device's presence and monitors each Presence tracker shard, so that the channel
  can track again if one crashes. Monitoring the supervisor is not sufficient, because a shard
  crash under `:one_for_one` does not stop the supervisor. While Presence is down,
  `:track_presence` is sent again shortly.
  """
  @spec track_presence(Phoenix.Socket.t(), Portal.Device.t(), Ecto.UUID.t(), map()) ::
          Phoenix.Socket.t()
  def track_presence(socket, device, token_id, meta) do
    case Process.whereis(Portal.Presence) do
      nil ->
        Process.send_after(self(), :track_presence, 50)
        socket

      sup_pid ->
        :ok = Presence.Devices.connect(device, token_id, meta)

        for {_pid, ref} <- socket.assigns[:presence_monitors] || [] do
          Process.demonitor(ref, [:flush])
        end

        monitors =
          for {_, pid, _, _} <- Supervisor.which_children(sup_pid), is_pid(pid) do
            {pid, Process.monitor(pid)}
          end

        assign(socket, :presence_monitors, monitors)
    end
  end

  @doc "What a `:DOWN` message is for: the `Portal.PG` scope, a Presence shard, or neither."
  @spec monitored(Phoenix.Socket.t(), pid()) :: :pg_scope | :presence | nil
  def monitored(socket, pid) do
    cond do
      pid == socket.assigns[:pg_scope_pid] -> :pg_scope
      List.keymember?(socket.assigns[:presence_monitors] || [], pid, 0) -> :presence
      true -> nil
    end
  end

  defp abnormal_exit?(:normal), do: false
  defp abnormal_exit?(:shutdown), do: false
  defp abnormal_exit?({:shutdown, _reason}), do: false
  defp abnormal_exit?(_reason), do: true
end
