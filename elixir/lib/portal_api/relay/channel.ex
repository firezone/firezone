defmodule PortalAPI.Relay.Channel do
  use PortalAPI, :channel
  alias Portal.{Changes.Change, Presence, PubSub}
  alias __MODULE__.Database
  require OpenTelemetry.Tracer
  require Logger

  @impl true
  def join("relay", %{"stamp_secret" => stamp_secret} = payload, socket) do
    OpenTelemetry.Ctx.attach(socket.assigns.opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(socket.assigns.opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "relay.join" do
      opentelemetry_ctx = OpenTelemetry.Ctx.get_current()
      opentelemetry_span_ctx = OpenTelemetry.Tracer.current_span_ctx()
      turn_account_validation = payload["turn_account_validation"] == true

      send(
        self(),
        {:after_join, stamp_secret, turn_account_validation,
         {opentelemetry_ctx, opentelemetry_span_ctx}}
      )

      socket =
        assign(socket,
          opentelemetry_ctx: opentelemetry_ctx,
          opentelemetry_span_ctx: opentelemetry_span_ctx
        )

      {:ok, socket}
    end
  end

  # On an abnormal exit, drain the whole WebSocket instead of just letting the
  # channel die. connlib ignores `phx_error` and would keep the transport alive,
  # re-joining reactively while presence stays dead. Draining forces a full
  # reconnect that re-runs the join and re-establishes presence. Graceful stops
  # already send `phx_close`, so we only intervene here.
  @impl true
  def terminate(reason, socket) do
    if abnormal_exit?(reason) do
      send(socket.transport_pid, :socket_drain)
    end

    :ok
  end

  @impl true
  def handle_info(
        {:after_join, stamp_secret, turn_account_validation,
         {opentelemetry_ctx, opentelemetry_span_ctx}},
        socket
      ) do
    OpenTelemetry.Ctx.attach(opentelemetry_ctx)
    OpenTelemetry.Tracer.set_current_span(opentelemetry_span_ctx)

    OpenTelemetry.Tracer.with_span "relay.after_join" do
      relay = socket.assigns.relay

      # Generate the relay ID from the stamp_secret and connect
      relay = %{
        relay
        | id: Portal.Relay.generate_id(stamp_secret),
          stamp_secret: stamp_secret,
          turn_account_validation: turn_account_validation
      }

      # Old Relay binaries ignore unknown fields on `init`, but fail their
      # Portal connection on unknown events. Account updates therefore remain
      # capability-gated, while the initial snapshot uses the existing event.
      init_payload =
        if turn_account_validation do
          :ok = PubSub.Changes.subscribe_to_accounts()

          %{
            account_ids: Database.all_enabled_account_ids()
          }
        else
          %{}
        end

      push(socket, "init", init_payload)
      :ok = Presence.Relays.connect(relay)

      {:noreply, assign(socket, :relay, relay)}
    end
  end

  @impl true
  def handle_info(%Change{lsn: lsn} = change, socket) do
    last_lsn = socket.assigns[:last_lsn] || 0

    if lsn > last_lsn do
      case change do
        %Change{op: :insert, struct: %Portal.Account{id: id}} ->
          push(socket, "account_added", %{account_id: id})

        %Change{op: :delete, old_struct: %Portal.Account{id: id}} ->
          push(socket, "account_removed", %{account_id: id})

        _ ->
          :ok
      end

      {:noreply, assign(socket, :last_lsn, lsn)}
    else
      # CDC changes can be replayed after a reconnect. The Relay cache is
      # idempotent, but avoiding stale creates after a newer removal keeps the
      # Portal and Relay convergent.
      {:noreply, socket}
    end
  end

  # Catch-all for unknown messages
  @impl true
  def handle_in(message, payload, socket) do
    Logger.error("Unknown relay message", message: message, payload: payload)

    {:reply, {:error, %{reason: :unknown_message}}, socket}
  end

  defp abnormal_exit?(:normal), do: false
  defp abnormal_exit?(:shutdown), do: false
  defp abnormal_exit?({:shutdown, _reason}), do: false
  defp abnormal_exit?(_reason), do: true

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def all_enabled_account_ids do
      from(account in Portal.Account,
        where: account.is_disabled == false,
        select: account.id
      )
      |> Safe.unscoped()
      |> Safe.all()
    end
  end
end
