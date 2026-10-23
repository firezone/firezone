defmodule PortalAPI.Device.Channel.Relays do
  @moduledoc """
  Relay selection and relay presence for every device channel.

  A channel hands over a `peer/0` describing the device it serves: where it
  connects from, the public key that salts its TURN credentials, when those
  credentials expire and the account they belong to. Everything else, which
  relays to offer, when to tell the device that relays came and went, and
  how to render them, is the same for a client and a gateway.
  """

  import Phoenix.Channel, only: [push: 3]
  import Phoenix.Socket, only: [assign: 3]

  alias Portal.Presence

  @typedoc "The device a channel serves, as relay selection sees it."
  @type peer :: %{
          location: {float() | nil, float() | nil},
          public_key: String.t(),
          credentials_expire_at: DateTime.t(),
          account_id: Ecto.UUID.t()
        }

  @doc """
  Picks the relays for `peer`, remembers them on the socket and subscribes
  to relay presence so the channel learns when they come and go.
  """
  @spec subscribe_and_select(Phoenix.Socket.t(), peer()) :: {Phoenix.Socket.t(), [Portal.Relay.t()]}
  def subscribe_and_select(socket, peer) do
    :ok = Presence.Relays.subscribe()
    select(socket, peer)
  end

  @doc "Picks the relays for `peer`, skipping `except_ids`, and remembers them on the socket."
  @spec select(Phoenix.Socket.t(), peer(), [Ecto.UUID.t()]) ::
          {Phoenix.Socket.t(), [Portal.Relay.t()]}
  def select(socket, peer, except_ids \\ []) do
    {:ok, relays} = Presence.Relays.all_connected_relays(except_ids)
    relays = load_balance(peer.location, relays)

    {cache(socket, relays), relays}
  end

  @doc "The relays as the device receives them, with TURN credentials for `peer`."
  @spec render([Portal.Relay.t()], peer()) :: [map()]
  def render(relays, peer) do
    PortalAPI.Client.Views.Relay.render_many(
      relays,
      peer.public_key,
      peer.credentials_expire_at,
      peer.account_id
    )
  end

  @doc """
  Debounces a relay presence change: only the last event in a burst leads to
  a check, which `handle_presence_check/3` runs.
  """
  @spec handle_presence_diff(Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def handle_presence_diff(socket) do
    if timer_ref = socket.assigns[:relay_presence_timer_ref] do
      Process.cancel_timer(timer_ref)
    end

    # A unique reference identifies this timer, so a stale message already in
    # the mailbox when the timer was cancelled is told from the live one.
    ref = make_ref()
    debounce_ms = Portal.Config.get_env(:portal, :relay_presence_debounce_ms, 1_000)
    timer_ref = Process.send_after(self(), {:check_relay_presence, ref}, debounce_ms)

    socket =
      socket
      |> assign(:relay_presence_timer_ref, timer_ref)
      |> assign(:relay_presence_ref, ref)

    {:noreply, socket}
  end

  @doc """
  Tells the device which of its relays went away and which to use instead,
  when any did or when it has fewer than two and more are available.
  """
  @spec handle_presence_check(Phoenix.Socket.t(), reference(), peer()) ::
          {:noreply, Phoenix.Socket.t()}
  def handle_presence_check(socket, ref, peer) do
    if ref != socket.assigns[:relay_presence_ref] do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:relay_presence_timer_ref, nil)
        |> assign(:relay_presence_ref, nil)

      cached_relay_ids = socket.assigns[:cached_relay_ids] || MapSet.new()

      # One presence snapshot serves both the disconnected list and the new
      # selection, so a relay flapping between the two queries cannot end up
      # in both.
      {:ok, all_online_relays} = Presence.Relays.all_connected_relays()
      online_relay_ids = MapSet.new(all_online_relays, & &1.id)

      disconnected_ids =
        cached_relay_ids
        |> Enum.reject(&MapSet.member?(online_relay_ids, &1))
        |> Enum.to_list()

      needs_update =
        disconnected_ids != [] or
          (MapSet.size(cached_relay_ids) < 2 and MapSet.size(online_relay_ids) > 0)

      if needs_update do
        relays = load_balance(peer.location, all_online_relays)
        socket = cache(socket, relays)

        push(socket, "relays_presence", %{
          disconnected_ids: disconnected_ids,
          connected: render(relays, peer)
        })

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    end
  end

  @doc "Answers a device that could reach none of its relays with a fresh pick."
  @spec handle_no_relays(Phoenix.Socket.t(), map(), peer()) :: {:noreply, Phoenix.Socket.t()}
  def handle_no_relays(socket, payload, peer) do
    {socket, relays} = select(socket, peer, excluded_relay_ids(payload))

    push(socket, "relays_presence", %{
      disconnected_ids: [],
      connected: render(relays, peer)
    })

    {:noreply, socket}
  end

  defp cache(socket, relays) do
    assign(socket, :cached_relay_ids, MapSet.new(relays, & &1.id))
  end

  defp excluded_relay_ids(%{"excluded_relay_ids" => ids}) when is_list(ids) do
    Enum.flat_map(ids, fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, id} -> [id]
        :error -> []
      end
    end)
  end

  defp excluded_relay_ids(_payload), do: []

  defp load_balance({lat, lon}, relays) when is_nil(lat) or is_nil(lon) do
    relays
    |> Enum.shuffle()
    |> Enum.take(2)
  end

  defp load_balance({lat, lon}, relays) do
    relays
    |> Enum.map(fn relay ->
      case {relay.lat, relay.lon} do
        {nil, _} -> {nil, relay}
        {_, nil} -> {nil, relay}
        {relay_lat, relay_lon} -> {Portal.Geo.distance({lat, lon}, {relay_lat, relay_lon}), relay}
      end
    end)
    |> Enum.sort_by(&elem(&1, 0), &nils_last/2)
    |> Enum.take(2)
    |> Enum.map(&elem(&1, 1))
  end

  defp nils_last(nil, _), do: false
  defp nils_last(_, nil), do: true
  defp nils_last(a, b), do: a <= b
end
