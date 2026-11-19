defmodule PortalAPI.Channel.Relays do
  @moduledoc """
  Relays for a device's channel, shared by Clients and Gateways.

  The `owner` is the connected device, the location relays are ranked from,
  and the expiry of the relay credentials it gets.
  """
  import Phoenix.Channel, only: [push: 3]
  import Phoenix.Socket, only: [assign: 3]

  alias Portal.{Device, Presence, Routing}
  alias PortalAPI.Client.Views

  @type owner :: %{
          device: Device.t(),
          location: {number() | nil, number() | nil},
          expires_at: DateTime.t()
        }

  @spec select(owner(), [Ecto.UUID.t()]) :: [Portal.Relay.t()]
  def select(owner, except_ids \\ []) do
    {:ok, relays} = Presence.Relays.all_connected_relays(except_ids)
    Routing.select_relays(relays, owner.location)
  end

  # Every relay we handed out and did not report disconnected: connlib may still
  # hold an allocation on any of them.
  @spec cache(Phoenix.Socket.t(), [Portal.Relay.t()], [Ecto.UUID.t()]) :: Phoenix.Socket.t()
  def cache(socket, relays, removed_ids \\ []) do
    cached_relay_ids =
      (socket.assigns[:cached_relay_ids] || MapSet.new())
      |> MapSet.difference(MapSet.new(removed_ids))
      |> MapSet.union(MapSet.new(relays, fn relay -> relay.id end))

    assign(socket, :cached_relay_ids, cached_relay_ids)
  end

  @spec render([Portal.Relay.t()], owner()) :: [map()]
  def render(relays, owner) do
    Views.Relay.render_many(relays, owner.device, owner.expires_at, owner.device.account_id)
  end

  # Instead of reacting to a relay presence change immediately, a check is
  # scheduled; only the last change in a burst triggers it.
  @spec schedule_check(Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def schedule_check(socket) do
    if timer_ref = socket.assigns[:relay_presence_timer_ref] do
      Process.cancel_timer(timer_ref)
    end

    # A message already in the mailbox when its timer was cancelled carries an
    # old ref and is ignored by check/3.
    ref = make_ref()
    debounce_ms = Portal.Config.get_env(:portal, :relay_presence_debounce_ms, 1_000)
    timer_ref = Process.send_after(self(), {:check_relay_presence, ref}, debounce_ms)

    socket =
      socket
      |> assign(:relay_presence_timer_ref, timer_ref)
      |> assign(:relay_presence_ref, ref)

    {:noreply, socket}
  end

  @spec check(Phoenix.Socket.t(), reference(), owner()) :: {:noreply, Phoenix.Socket.t()}
  def check(socket, ref, owner) do
    if ref != socket.assigns[:relay_presence_ref] do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:relay_presence_timer_ref, nil)
        |> assign(:relay_presence_ref, nil)

      push_changes(socket, owner)
    end
  end

  @spec no_relays(Phoenix.Socket.t(), map(), owner()) :: {:noreply, Phoenix.Socket.t()}
  def no_relays(socket, payload, owner) do
    relays = select(owner, excluded_ids(payload))
    socket = cache(socket, relays)

    push(socket, "relays_presence", %{disconnected_ids: [], connected: render(relays, owner)})

    {:noreply, socket}
  end

  # One presence snapshot decides both which relays went away and which to
  # hand out, so rapid reconnects cannot make the two disagree.
  defp push_changes(socket, owner) do
    cached_relay_ids = socket.assigns[:cached_relay_ids] || MapSet.new()
    {:ok, all_online_relays} = Presence.Relays.all_connected_relays()
    online_relay_ids = MapSet.new(all_online_relays, & &1.id)

    disconnected_ids =
      cached_relay_ids
      |> Enum.reject(&MapSet.member?(online_relay_ids, &1))
      |> Enum.to_list()

    # Also update a device with fewer than 2 relays once more are online.
    needs_update =
      disconnected_ids != [] or
        (MapSet.size(cached_relay_ids) < 2 and not MapSet.subset?(online_relay_ids, cached_relay_ids))

    if needs_update do
      relays = Routing.select_relays(all_online_relays, owner.location)
      socket = cache(socket, relays, disconnected_ids)

      push(socket, "relays_presence", %{
        disconnected_ids: disconnected_ids,
        connected: render(relays, owner)
      })

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp excluded_ids(%{"excluded_relay_ids" => ids}) when is_list(ids) do
    Enum.flat_map(ids, fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, id} -> [id]
        :error -> []
      end
    end)
  end

  defp excluded_ids(_payload), do: []
end
