defmodule PortalAPI.Gateway.Socket do
  use Phoenix.Socket
  alias Portal.{PG, SessionLog}
  alias Portal.Repo.Batch
  alias PortalAPI.Gateway.Connection
  alias PortalAPI.Sockets
  alias Portal.Types.LogId
  require Logger

  ## Channels

  channel "gateway", PortalAPI.Gateway.Channel

  @doc false
  def gateway_session_queue_opts do
    [
      name: Portal.Queue.name(:gateway_session_queue),
      flush_interval: :timer.seconds(5),
      flush_threshold: 1_000,
      label: "gateway session",
      on_flush: &flush_gateway_sessions/1
    ]
  end

  ## Authentication

  @impl true
  def connect(attrs, socket, connect_info) do
    with {:ok, assigns} <- Connection.connect(attrs, connect_info) do
      {:ok, assign(socket, assigns)}
    end
  end

  @impl true
  def id(socket), do: Portal.Sockets.socket_id(socket.assigns.token_id)

  defp flush_gateway_sessions(entries) do
    {persisted, revoked, missing} = Sockets.LatestSession.upsert_all(entries)

    failed = revoked ++ missing
    failed_session_refs = MapSet.new(failed, fn {attrs, _metadata} -> attrs.session_ref end)

    # A deleted token fails only its own session: a successor connection on
    # the same device may hold a valid token, so the disconnect carries the
    # session_ref for the channel to match on. A deleted device takes every
    # connection down with it.
    for {attrs, _metadata} <- revoked do
      dispatch_queue_callback("gateway session", :on_failed, attrs, fn ->
        PG.deliver(attrs.device_id, {:disconnect, attrs.session_ref})
      end)
    end

    for {attrs, _metadata} <- missing do
      dispatch_queue_callback("gateway session", :on_failed, attrs, fn ->
        PG.deliver(attrs.device_id, :disconnect)
      end)
    end

    # Durability is confirmed only once both the device upsert and the log have
    # landed: a session whose log write fails is left unconfirmed so its
    # durability timer fires and the gateway reconnects to retry both. This
    # keeps the session log fail-closed without a transaction spanning the
    # upsert and the log insert.
    log_failed_session_refs = insert_session_logs(entries, failed_session_refs)
    dispatch_gateway_session_confirmed(entries, MapSet.union(failed_session_refs, log_failed_session_refs))

    if failed != [] do
      Logger.info(
        "Skipped #{length(failed)} gateway session entries during flush due to deleted devices or tokens"
      )
    end

    persisted
  end

  defp dispatch_gateway_session_confirmed(entries, failed_session_refs) do
    for {attrs, _metadata} <- entries, not MapSet.member?(failed_session_refs, attrs.session_ref) do
      dispatch_queue_callback("gateway session", :on_confirmed, attrs, fn ->
        PG.deliver(attrs.device_id, {:confirm_session_durability, attrs.session_ref})
      end)
    end
  end

  # Session logs ride the same flushed batch that persists the sessions, so a
  # reconnect storm collapses into one bulk insert here rather than a write per
  # connect. Only durable sessions are logged. Gateways authenticate with a
  # token and have no actor, so the subject snapshot is the gateway identity
  # and its connection context. The connect-time timestamp rides the queue
  # entry's metadata rather than the session row's flush-time inserted_at. Each
  # log entry carries its session_ref so the caller can learn which sessions'
  # logs failed and withhold their durability confirmation.
  defp insert_session_logs(entries, failed_session_refs) do
    log_entries =
      for {attrs, metadata} <- entries, not MapSet.member?(failed_session_refs, attrs.session_ref) do
        {session_log_attrs(attrs, metadata), attrs.session_ref}
      end

    {_inserted, failed} =
      Batch.insert_all(SessionLog, log_entries,
        label: "gateway session log",
        fk_partitions: %{
          "session_logs_partitioned_account_id_fkey" => {:simple, :account_id, Portal.Account}
        }
      )

    MapSet.new(failed, fn {_log_attrs, session_ref} -> session_ref end)
  end

  defp session_log_attrs(attrs, %{timestamp: timestamp}) do
    %{
      account_id: attrs.account_id,
      log_id: LogId.build_session_log(),
      timestamp: timestamp,
      context: :gateway,
      subject: %{
        gateway_id: attrs[:device_id],
        token_id: attrs[:token_id],
        ip: format_ip(attrs[:remote_ip]),
        ip_region: attrs[:remote_ip_location_region],
        ip_city: attrs[:remote_ip_location_city],
        ip_lat: attrs[:remote_ip_location_lat],
        ip_lon: attrs[:remote_ip_location_lon],
        user_agent: attrs[:user_agent]
      }
    }
  end

  defp format_ip(nil), do: nil
  defp format_ip(%Postgrex.INET{address: address}), do: to_string(:inet.ntoa(address))
  defp format_ip(address) when is_tuple(address), do: to_string(:inet.ntoa(address))

  defp dispatch_queue_callback(label, callback, attrs, fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.error(
        "Queue #{label} #{callback} crashed for entry #{inspect(attrs[:session_ref])}: " <>
          Exception.message(error)
      )
  catch
    kind, reason ->
      Logger.error(
        "Queue #{label} #{callback} threw #{kind} for entry #{inspect(attrs[:session_ref])}: " <>
          inspect(reason)
      )
  end
end
