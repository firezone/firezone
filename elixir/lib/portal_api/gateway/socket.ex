defmodule PortalAPI.Gateway.Socket do
  use Phoenix.Socket
  alias Portal.Authentication
  alias Portal.{Device, PG, SessionLog, Version}
  alias Portal.Repo.Batch
  alias PortalAPI.Sockets
  alias Portal.Types.LogId
  alias __MODULE__.Database
  require Logger
  require OpenTelemetry.Tracer
  import Ecto.Changeset
  import Portal.Changeset

  @reported_metadata_fields ~w[
    device_serial
    device_uuid
  ]a

  ## Channels

  channel "gateway", PortalAPI.Gateway.Channel

  @doc false
  def gateway_session_queue_opts do
    [
      name: :gateway_session_queue,
      flush_interval: :timer.seconds(5),
      flush_threshold: 1_000,
      label: "gateway session",
      on_flush: &flush_gateway_sessions/1
    ]
  end

  ## Authentication

  @impl true
  def connect(attrs, socket, connect_info) do
    unless Application.get_env(:portal, :sql_sandbox) do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Api)
    end

    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "gateway.connect" do
      with {:ok, encoded_token} <- PortalAPI.Sockets.extract_token(attrs, connect_info),
           :ok <- PortalAPI.Sockets.RateLimit.check(connect_info, token: encoded_token) do
        do_connect(encoded_token, attrs, socket, connect_info)
      end
    end
  end

  @impl true
  def id(socket), do: Portal.Sockets.socket_id(socket.assigns.token_id)

  defp do_connect(encoded_token, attrs, socket, connect_info) do
    context = PortalAPI.Sockets.auth_context(connect_info, :gateway)
    attrs = normalize_device_attrs(attrs)

    with {:ok, gateway_token} <- Authentication.verify_gateway_token(encoded_token),
         {:ok, subject} <- Authentication.build_subject(gateway_token, context),
         {:ok, public_key} <- validate_public_key(attrs),
         {:ok, site, gateway} <- resolve_gateway(gateway_token, attrs, subject),
         :ok <- ensure_gateway_not_connected(gateway),
         {:ok, gateway} <- put_reported_metadata(gateway, attrs, subject),
         {:ok, gateway} <- maybe_put_firezone_id(gateway, site, attrs, subject) do
      version = derive_version(context.user_agent)
      {context, version} = PortalAPI.Sockets.truncate_session_fields(context, version)
      previous_public_key = gateway.public_key
      gateway = apply_session(gateway, gateway_token.id, public_key, context, version)

      OpenTelemetry.Tracer.set_attributes(%{
        token_id: gateway_token.id,
        gateway_id: gateway.id,
        account_id: gateway.account_id,
        version: version
      })

      socket =
        socket
        |> assign(:token_id, gateway_token.id)
        |> assign(:subject, subject)
        |> assign(:site, site)
        |> assign(:gateway, gateway)
        |> assign(:previous_public_key, previous_public_key)
        |> assign(:session_ref, make_ref())
        |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
        |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())

      {:ok, socket}
    else
      {:error, {:rate_limit, retry_after_ms}} ->
        {:error, {:rate_limit, retry_after_ms}}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset = public_socket_changeset(changeset)
        trace = Process.info(self(), :current_stacktrace)

        Logger.info("Gateway socket connection failed",
          error: {:error, changeset},
          stacktrace: trace
        )

        {:error, changeset}

      error ->
        trace = Process.info(self(), :current_stacktrace)
        Logger.info("Gateway socket connection failed", error: error, stacktrace: trace)

        error
    end
  end

  # First-wins: a gateway that appears connected must disconnect before a
  # replacement is allowed. Cross-node registration races are resolved by the
  # channel's connection-claim protocol after join.
  defp ensure_gateway_not_connected(gateway) do
    case PG.members(gateway.id) do
      [] -> :ok
      _pids -> {:error, :conflict}
    end
  end

  # Multi-owner (site) token: gateways are identified by their reported
  # firezone_id and created on the fly
  defp resolve_gateway(%Portal.DeviceToken{device_id: nil} = gateway_token, attrs, subject) do
    with {:ok, site} <- Database.fetch_site(gateway_token.site_id, subject),
         changeset = insert_changeset(site, attrs),
         {:ok, _} <- apply_action(changeset, :validate),
         {:ok, gateway} <- Database.find_or_create_gateway(site, changeset, subject) do
      {:ok, site, gateway}
    end
  end

  # Single-owner token: the token identifies the gateway directly; the
  # reported firezone_id is kept in sync as a telemetry hint
  defp resolve_gateway(%Portal.DeviceToken{} = gateway_token, _attrs, subject) do
    with {:ok, gateway} <- Database.fetch_gateway(gateway_token.device_id, subject) do
      {:ok, gateway.site_device.site, gateway}
    end
  end

  # Hardware metadata is self-reported on every connection. Only fields present
  # in the socket params are cast, so an older gateway that omits a field keeps
  # the value already stored on its device row.
  defp put_reported_metadata(%Device{} = gateway, attrs, subject) do
    changeset =
      gateway
      |> cast(attrs, @reported_metadata_fields)
      |> Device.changeset()

    if changeset.changes == %{} do
      {:ok, gateway}
    else
      Database.update_gateway(changeset, subject)
    end
  end

  # Identity comes from the token, so the stored firezone_id is only a
  # telemetry hint: keep it in sync with whatever the gateway currently
  # reports (a rebuilt host generates a fresh one)
  defp maybe_put_firezone_id(
         %Device{firezone_id: reported} = gateway,
         _site,
         %{"firezone_id" => reported},
         _subject
       ) do
    {:ok, gateway}
  end

  defp maybe_put_firezone_id(%Device{} = gateway, site, %{"firezone_id" => reported}, subject)
       when is_binary(reported) and reported != "" do
    changeset =
      gateway
      |> cast(%{firezone_id: reported}, [:firezone_id])
      |> Device.changeset()

    case Database.update_firezone_id(site, changeset, subject) do
      {:ok, gateway} ->
        {:ok, gateway}

      {:error, reason} ->
        # The telemetry hint is best-effort; never block the connection on it
        Logger.info("Failed to persist reported gateway firezone_id", error: {:error, reason})

        {:ok, gateway}
    end
  end

  defp maybe_put_firezone_id(%Device{} = gateway, _site, _attrs, _subject), do: {:ok, gateway}

  defp insert_changeset(site, attrs) do
    insert_fields = [:firezone_id, :name | @reported_metadata_fields]
    required_fields = ~w[firezone_id name]a

    %Device{}
    |> cast(attrs, insert_fields)
    |> put_default_value(:name, fn ->
      Portal.Crypto.random_token(5, encoder: :user_friendly)
    end)
    |> put_change(:type, :gateway)
    |> put_change(:account_id, site.account_id)
    |> Portal.Devices.put_free_slug(site.account_id, nil)
    |> put_assoc(:site_device, Portal.Devices.site_device_changeset(site))
    |> validate_required(required_fields)
    |> Device.changeset()
    |> public_socket_changeset()
  end

  # The connection snapshot lives directly on the device struct: these are the
  # same fields the flush later persists as the device's latest session.
  defp apply_session(gateway, token_id, public_key, context, version) do
    %{
      gateway
      | gateway_token_id: token_id,
        token_id: token_id,
        public_key: public_key,
        last_seen_user_agent: context.user_agent,
        last_seen_remote_ip: context.remote_ip,
        last_seen_remote_ip_location_region: context.remote_ip_location_region,
        last_seen_remote_ip_location_city: context.remote_ip_location_city,
        last_seen_remote_ip_location_lat: context.remote_ip_location_lat,
        last_seen_remote_ip_location_lon: context.remote_ip_location_lon,
        last_seen_version: version,
        last_seen_at: DateTime.utc_now()
    }
  end

  defp flush_gateway_sessions(entries) do
    {persisted, revoked, missing} = Sockets.LatestSession.upsert_all(entries, :gateway_token_id)

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
        token_id: attrs[:gateway_token_id],
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

  defp validate_public_key(attrs) do
    changeset =
      {%{}, %{public_key: :string}}
      |> cast(attrs, [:public_key])
      |> validate_required([:public_key])
      |> validate_base64(:public_key)
      |> validate_length(:public_key, is: 44)

    case apply_action(changeset, :validate) do
      {:ok, %{public_key: public_key}} -> {:ok, public_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp derive_version(user_agent) do
    case Version.fetch_version(user_agent) do
      {:ok, version} -> version
      _ -> nil
    end
  end

  defp normalize_device_attrs(attrs) do
    firezone_id =
      attrs["external_id"] || attrs[:external_id] || attrs["firezone_id"] || attrs[:firezone_id]

    if firezone_id do
      Map.put(attrs, "firezone_id", firezone_id)
    else
      attrs
    end
  end

  defp public_socket_changeset(changeset) do
    %{changeset | errors: rename_firezone_id_errors(changeset.errors)}
  end

  defp rename_firezone_id_errors(errors) do
    Enum.map(errors, fn
      {:firezone_id, details} -> {:external_id, details}
      error -> error
    end)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Device

    alias Portal.Safe
    alias Portal.Site
    alias Portal.SiteDevice

    # Connect hot path: the site rides along in the same query.
    def fetch_gateway(id, subject) do
      result =
        from(d in Device,
          where: d.id == ^id,
          where: d.type == :gateway,
          join: sd in SiteDevice,
          on: sd.account_id == d.account_id and sd.device_id == d.id,
          join: s in Site,
          on: s.account_id == sd.account_id and s.id == sd.site_id,
          preload: [site_device: {sd, site: s}]
        )
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        %Device{} = gateway -> {:ok, gateway}
        nil -> {:error, :not_found}
        {:error, :unauthorized} = error -> error
      end
    end

    def update_gateway(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    # Site-token connects find a gateway by its firezone_id, so a gateway only
    # takes one that no other gateway in its site holds.
    def update_firezone_id(site, changeset, subject) do
      firezone_id = Ecto.Changeset.get_field(changeset, :firezone_id)

      Safe.transact(fn ->
        {:ok, _} =
          Safe.unscoped()
          |> Safe.query("SELECT pg_advisory_xact_lock($1)", [registration_lock_key(site, firezone_id)])

        case find_gateway(site, firezone_id, subject) do
          nil -> update_gateway(changeset, subject)
          %Device{} -> {:error, :firezone_id_taken}
          {:error, :unauthorized} = error -> error
        end
      end)
    end

    def fetch_site(id, subject) do
      result =
        from(s in Site, where: s.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        %Site{} = site -> {:ok, site}
        nil -> {:error, :not_found}
        {:error, :unauthorized} = error -> error
      end
    end

    # The lookup runs again under a lock so two first connects of one gateway
    # cannot both insert it.
    def find_or_create_gateway(site, changeset, subject) do
      firezone_id = Ecto.Changeset.get_field(changeset, :firezone_id)

      case find_gateway(site, firezone_id, subject) do
        nil -> Safe.transact(fn -> find_or_insert_locked(site, firezone_id, changeset, subject) end)
        %Device{} = gateway -> {:ok, gateway}
        {:error, :unauthorized} = error -> error
      end
    end

    defp find_or_insert_locked(site, firezone_id, changeset, subject) do
      {:ok, _} =
        Safe.unscoped()
        |> Safe.query("SELECT pg_advisory_xact_lock($1)", [registration_lock_key(site, firezone_id)])

      case find_gateway(site, firezone_id, subject) do
        nil -> insert_gateway(changeset, subject)
        %Device{} = gateway -> {:ok, gateway}
        {:error, :unauthorized} = error -> error
      end
    end

    defp find_gateway(site, firezone_id, subject) do
      from(d in Device,
        join: sd in SiteDevice,
        on: sd.account_id == d.account_id and sd.device_id == d.id,
        where: sd.site_id == ^site.id,
        where: d.firezone_id == ^firezone_id,
        where: d.type == :gateway,
        order_by: [asc: d.inserted_at, asc: d.id],
        limit: 1
      )
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    @dialyzer {:no_opaque, [insert_gateway: 2]}
    defp insert_gateway(changeset, subject) do
      with :ok <- Portal.Devices.RegistrationRateLimit.check(subject.account) do
        changeset |> Safe.scoped(subject) |> Safe.insert()
      end
    end

    defp registration_lock_key(site, firezone_id) do
      <<key::signed-64, _::binary>> =
        :crypto.hash(:sha256, "gateway_registration:" <> site.id <> ":" <> firezone_id)

      key
    end
  end
end
