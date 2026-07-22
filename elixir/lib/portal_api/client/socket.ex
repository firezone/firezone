defmodule PortalAPI.Client.Socket do
  use Phoenix.Socket
  alias Portal.{Authentication, Device, PG, SessionLog, Version}
  alias Portal.Repo.Batch
  alias PortalAPI.Client.DeviceTrust
  alias PortalAPI.Sockets
  alias Portal.Types.LogId
  alias __MODULE__.Database
  require Logger
  require OpenTelemetry.Tracer
  import Ecto.Changeset
  import Portal.Changeset

  ## Channels

  channel "client", PortalAPI.Client.Channel

  @doc false
  def client_session_queue_opts do
    [
      name: :client_session_queue,
      flush_interval: :timer.seconds(5),
      flush_threshold: 1_000,
      label: "client session",
      on_flush: &flush_client_sessions/1
    ]
  end

  ## Authentication

  @impl true
  def connect(attrs, socket, connect_info) do
    handle_connect(attrs, socket, connect_info, :resolve)
  end

  @doc false
  # Entry point for /client/v3 sockets: token auth as usual, but on accounts
  # with the device-trust gate enabled the device resolution is deferred until
  # after the channel's challenge round trip (see PortalAPI.Client.V3.Channel).
  def connect_deferring(attrs, socket, connect_info) do
    handle_connect(attrs, socket, connect_info, :defer_if_enabled)
  end

  @impl true
  def id(socket) do
    Portal.Sockets.socket_id(socket.assigns.subject.credential.id)
  end

  @doc false
  # Resolves a deferred device after the challenge round trip (or its
  # timeout). `verified` is the DeviceTrust verification result or nil when
  # the challenge failed, timed out, or produced no usable certificate.
  def resolve_deferred_client(socket, verified) do
    %{
      changeset: changeset,
      attrs: attrs,
      token_id: token_id,
      public_key: public_key,
      version: version
    } = socket.assigns.pending_device

    with {:ok, client} <- Database.resolve_client(changeset, attrs, verified) do
      client = apply_session(client, token_id, public_key, socket.assigns.subject, version)
      set_connect_attributes(token_id, client, socket.assigns.subject, version)

      socket =
        socket
        |> assign(:client, client)
        |> assign(:pending_device, nil)

      {:ok, socket}
    end
  end

  ## Private functions

  defp handle_connect(attrs, socket, connect_info, mode) do
    unless Application.get_env(:portal, :sql_sandbox) do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Api)
      Portal.Repo.Replica.put_dynamic_repo(Portal.Repo.Replica.Api)
    end

    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "client.connect" do
      with {:ok, token} <- PortalAPI.Sockets.extract_token(attrs, connect_info),
           :ok <- PortalAPI.Sockets.RateLimit.check(connect_info, token: token) do
        do_connect(token, attrs, socket, connect_info, mode)
      end
    end
  end

  defp do_connect(token, attrs, socket, connect_info, mode) do
    context = PortalAPI.Sockets.auth_context(connect_info, :client)
    attrs = normalize_device_attrs(attrs)

    with {:ok, %{credential: %{type: :client_token, id: token_id}} = subject} <-
           Authentication.authenticate(token, context),
         false <- Portal.Billing.client_connect_restricted?(subject.account),
         {:ok, public_key} <- validate_public_key(attrs),
         changeset = insert_changeset(subject.actor, subject, attrs),
         {:ok, _} <- apply_action(changeset, :validate),
         {:ok, outcome} <- resolve_or_defer(changeset, attrs, subject, mode) do
      version = derive_version(subject.context.user_agent)
      {context, version} = PortalAPI.Sockets.truncate_session_fields(subject.context, version)
      subject = %{subject | context: context}

      case outcome do
        {:resolved, client} ->
          client = apply_session(client, token_id, public_key, subject, version)
          set_connect_attributes(token_id, client, subject, version)
          {:ok, assign_connect(socket, subject, client, version)}

        {:deferred, anchors} ->
          pending = %{
            changeset: changeset,
            attrs: attrs,
            token_id: token_id,
            public_key: public_key,
            version: version,
            anchors: anchors
          }

          {:ok, assign_connect_deferred(socket, subject, pending)}
      end
    else
      {:error, :invalid_token} ->
        OpenTelemetry.Tracer.set_status(:error, "invalid_token")
        {:error, :invalid_token}

      true ->
        OpenTelemetry.Tracer.set_status(:error, "limits_exceeded")
        {:error, :limits_exceeded}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset = public_socket_changeset(changeset)
        OpenTelemetry.Tracer.set_status(:error, inspect(changeset))
        Logger.debug("Error connecting client websocket: #{inspect(changeset)}")
        {:error, changeset}
    end
  end

  # One query decides the gate AND fetches the verification material: empty
  # anchors (feature off or none uploaded) resolve at connect exactly as
  # before, non-empty anchors ride the pending state so the challenge
  # response never re-fetches them.
  defp resolve_or_defer(changeset, attrs, subject, mode) do
    with :defer_if_enabled <- mode,
         [_ | _] = anchors <- DeviceTrust.fetch_enabled_anchors(subject.account.id) do
      {:ok, {:deferred, anchors}}
    else
      _resolve_now ->
        with {:ok, client} <- Database.find_or_create_client(changeset, attrs) do
          {:ok, {:resolved, client}}
        end
    end
  end

  # The connection snapshot lives directly on the device struct: these are the
  # same fields the flush later persists as the device's latest session.
  defp apply_session(client, token_id, public_key, subject, version) do
    %{
      client
      | client_token_id: token_id,
        public_key: public_key,
        last_seen_user_agent: subject.context.user_agent,
        last_seen_remote_ip: subject.context.remote_ip,
        last_seen_remote_ip_location_region: subject.context.remote_ip_location_region,
        last_seen_remote_ip_location_city: subject.context.remote_ip_location_city,
        last_seen_remote_ip_location_lat: subject.context.remote_ip_location_lat,
        last_seen_remote_ip_location_lon: subject.context.remote_ip_location_lon,
        last_seen_version: version,
        last_seen_at: DateTime.utc_now()
    }
  end

  defp flush_client_sessions(entries) do
    {persisted, revoked, missing} = Sockets.LatestSession.upsert_all(entries, :client_token_id)

    failed = revoked ++ missing
    failed_session_refs = MapSet.new(failed, fn {attrs, _metadata} -> attrs.session_ref end)

    # A deleted token fails only its own session: a successor connection on
    # the same device may hold a valid token, so the disconnect carries the
    # session_ref for the channel to match on. A deleted device takes every
    # connection down with it.
    for {attrs, _metadata} <- revoked do
      dispatch_queue_callback("client session", :on_failed, attrs, fn ->
        PG.deliver(attrs.device_id, {:disconnect, attrs.session_ref})
      end)
    end

    for {attrs, _metadata} <- missing do
      dispatch_queue_callback("client session", :on_failed, attrs, fn ->
        PG.deliver(attrs.device_id, :disconnect)
      end)
    end

    # Durability is confirmed only once both the device upsert and the log have
    # landed: a session whose log write fails is left unconfirmed so its
    # durability timer fires and the client reconnects to retry both. This
    # keeps the session log fail-closed without a transaction spanning the
    # upsert and the log insert.
    log_failed_session_refs = insert_session_logs(entries, failed_session_refs)
    dispatch_client_session_confirmed(entries, MapSet.union(failed_session_refs, log_failed_session_refs))

    if failed != [] do
      Logger.info(
        "Skipped #{length(failed)} client session entries during flush due to deleted devices or tokens"
      )
    end

    persisted
  end

  defp dispatch_client_session_confirmed(entries, failed_session_refs) do
    for {attrs, _metadata} <- entries, not MapSet.member?(failed_session_refs, attrs.session_ref) do
      dispatch_queue_callback("client session", :on_confirmed, attrs, fn ->
        PG.deliver(attrs.device_id, {:confirm_session_durability, attrs.session_ref})
      end)
    end
  end

  # Session logs are written from the same flushed batch that persists the
  # sessions, so a reconnect storm collapses into one bulk insert here instead
  # of one write per connect. Only durable sessions are logged: entries that
  # failed the session insert (deleted device/token) are skipped. The subject
  # snapshot and the connect-time timestamp ride the queue entry's metadata; the
  # timestamp is captured at connect rather than read from the session row's
  # inserted_at, which is stamped at flush time and would be identical across a
  # whole batch. Each log entry carries its session_ref so the caller can learn
  # which sessions' logs failed and withhold their durability confirmation.
  defp insert_session_logs(entries, failed_session_refs) do
    log_entries =
      for {attrs, metadata} <- entries, not MapSet.member?(failed_session_refs, attrs.session_ref) do
        {session_log_attrs(attrs, metadata), attrs.session_ref}
      end

    {_inserted, failed} =
      Batch.insert_all(SessionLog, log_entries,
        label: "client session log",
        fk_partitions: %{
          "session_logs_account_id_fkey" => {:simple, :account_id, Portal.Account}
        }
      )

    MapSet.new(failed, fn {_log_attrs, session_ref} -> session_ref end)
  end

  defp session_log_attrs(attrs, %{subject: subject, timestamp: timestamp}) do
    %{
      account_id: attrs.account_id,
      log_id: LogId.build_session_log(),
      timestamp: timestamp,
      context: :client,
      subject:
        Map.merge(subject || %{}, %{
          device_id: attrs[:device_id],
          token_id: attrs[:client_token_id]
        })
    }
  end

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

  defp set_connect_attributes(token_id, client, subject, version) do
    OpenTelemetry.Tracer.set_attributes(%{
      token_id: token_id,
      client_id: client.id,
      lat: subject.context.remote_ip_location_lat,
      lon: subject.context.remote_ip_location_lon,
      version: version,
      account_id: subject.account.id
    })
  end

  defp assign_connect(socket, subject, client, version) do
    socket
    |> assign(:subject, subject)
    |> assign(:client, client)
    |> assign(:session_ref, make_ref())
    |> assign(:client_version, version)
    |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
    |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())
  end

  defp assign_connect_deferred(socket, subject, pending) do
    socket
    |> assign(:subject, subject)
    |> assign(:pending_device, pending)
    |> assign(:session_ref, make_ref())
    |> assign(:client_version, pending.version)
    |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
    |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())
  end

  defp insert_changeset(actor, subject, attrs) do
    required_fields = ~w[firezone_id name]a

    hardware_identifiers =
      ~w[device_serial device_uuid identifier_for_vendor firebase_installation_id]a

    insert_fields = required_fields ++ hardware_identifiers

    %Device{}
    |> cast(attrs, insert_fields)
    |> put_default_value(:name, &generate_name/0)
    |> put_change(:type, :client)
    |> put_change(:actor_id, actor.id)
    |> put_change(:account_id, actor.account_id)
    |> validate_required(required_fields)
    |> Device.changeset()
    |> public_socket_changeset()
    |> validate_user_agent(subject.context.user_agent)
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

  defp validate_user_agent(changeset, user_agent) do
    case Version.fetch_version(user_agent) do
      {:ok, _version} -> changeset
      {:error, :invalid_user_agent} -> add_error(changeset, :user_agent, "is invalid")
    end
  end

  defp generate_name do
    name = Portal.NameGenerator.generate()

    hash =
      name
      |> :erlang.phash2(2 ** 16)
      |> Integer.to_string(16)
      |> String.pad_leading(4, "0")

    if String.length(name) > 15 do
      String.slice(name, 0..10) <> hash
    else
      name
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

  ## Database

  defmodule Database do
    import Ecto.Query
    alias Portal.Device
    alias Portal.Safe
    require Logger

    @hardware_id_fields ~w[device_serial device_uuid identifier_for_vendor firebase_installation_id]a
    @attested_id_fields ~w[last_attested_device_serial last_attested_device_uuid last_attested_mdm_device_id]a
    @verified_fields @attested_id_fields ++ ~w[last_attested_cert_serial last_attested_cert_fingerprint last_attested_at]a

    @dialyzer {:no_opaque,
               [find_or_create_client: 2, resolve_client: 3, find_by_attested_ids: 3]}
    def find_or_create_client(changeset, attrs) do
      resolve_client(changeset, attrs, nil)
    end

    # Resolves the connecting device. `verified` carries the DeviceTrust
    # challenge result (attested identifiers + pinned cert) or nil for
    # unattested connects, in which case this behaves exactly like the classic
    # firezone_id find-or-create.
    def resolve_client(changeset, attrs, verified) do
      account_id = Ecto.Changeset.get_field(changeset, :account_id)
      actor_id = Ecto.Changeset.get_field(changeset, :actor_id)
      firezone_id = Ecto.Changeset.get_field(changeset, :firezone_id)

      changeset = put_verified_changes(changeset, verified)

      case find_by_attested_ids(changeset, account_id, actor_id) do
        {:ok, client} ->
          check_hardware_id_mismatch(client, attrs)

          client =
            client
            |> merge_firezone_id(firezone_id)
            |> merge_verified(verified)

          {:ok, client}

        :identity_conflict ->
          # Identity conflict - the identifiers split across rows, or a
          # matched row disagrees on another identifier: refuse to adopt any
          # attested identity for this connect and fall back to the plain
          # firezone_id path, keeping the verified fields off the row and off
          # the changeset so a fallback insert cannot collide with the
          # conflicting rows' unique indexes.
          changeset
          |> strip_verified_changes()
          |> resolve_by_firezone_id(attrs, account_id, actor_id, firezone_id, nil)

        nil ->
          resolve_by_firezone_id(changeset, attrs, account_id, actor_id, firezone_id, verified)
      end
    end

    defp resolve_by_firezone_id(changeset, attrs, account_id, actor_id, firezone_id, verified) do
      if client = find_by_firezone_id(account_id, actor_id, firezone_id) do
        check_hardware_id_mismatch(client, attrs)

        client =
          cond do
            is_nil(verified) ->
              client

            consistent_attested?(client, verified.identifiers) ->
              merge_verified(client, verified)

            true ->
              log_attested_mismatch([client], verified.identifiers)
              client
          end

        {:ok, client}
      else
        changeset
        |> Safe.unscoped()
        |> Safe.insert()
      end
    end

    # Attested identifiers anchor a physical device, so they take precedence
    # over the client-reported firezone_id: a reinstalled client (new
    # firezone_id, same attested identity) merges back onto its existing device
    # row instead of creating a duplicate. Adoption requires the identifiers
    # to agree: all supplied identifiers must resolve to exactly one row (the
    # per-column unique indexes guarantee each identifier maps to at most
    # one), and every identifier that is non-NULL on both the row and the
    # certificate must match. Anything else is an identity conflict.
    defp find_by_attested_ids(changeset, account_id, actor_id) do
      filters =
        for field <- @attested_id_fields,
            value = Ecto.Changeset.get_field(changeset, field),
            not is_nil(value),
            do: {field, value}

      if filters == [] do
        nil
      else
        attested_match =
          Enum.reduce(filters, dynamic(false), fn {field, value}, dyn ->
            dynamic([d], ^dyn or field(d, ^field) == ^value)
          end)

        from(d in Device,
          where: d.account_id == ^account_id,
          where: d.actor_id == ^actor_id,
          where: d.type == :client,
          where: ^attested_match,
          order_by: [asc: d.inserted_at]
        )
        |> Safe.unscoped(:replica)
        |> Safe.all(fallback_to_primary: true)
        |> classify_attested_rows(Map.new(filters))
      end
    end

    defp classify_attested_rows([], _cert_identifiers), do: nil

    defp classify_attested_rows([client], cert_identifiers) do
      if consistent_attested?(client, cert_identifiers) do
        {:ok, client}
      else
        log_attested_mismatch([client], cert_identifiers)
        :identity_conflict
      end
    end

    # More than one distinct row means the identifiers split across devices;
    # adopting any of them would merge the connection onto an arbitrary device.
    defp classify_attested_rows(clients, cert_identifiers) do
      Logger.warning(
        "Attested identifiers split across multiple devices: refusing to adopt device identity",
        client_ids: Enum.map(clients, & &1.id),
        cert_identifiers: inspect(cert_identifiers),
        row_identifiers: inspect(Enum.map(clients, &Map.take(&1, @attested_id_fields)))
      )

      :identity_conflict
    end

    defp consistent_attested?(client, cert_identifiers) do
      Enum.all?(@attested_id_fields, fn field ->
        row_value = Map.get(client, field)
        cert_value = Map.get(cert_identifiers, field)

        is_nil(row_value) or is_nil(cert_value) or row_value == cert_value
      end)
    end

    defp log_attested_mismatch(clients, cert_identifiers) do
      Logger.warning(
        "Attested identifier mismatch: refusing to adopt device identity",
        client_ids: Enum.map(clients, & &1.id),
        cert_identifiers: inspect(cert_identifiers),
        row_identifiers:
          inspect(
            Enum.map(clients, fn client ->
              Map.take(client, @attested_id_fields)
            end)
          )
      )
    end

    defp put_verified_changes(changeset, nil), do: changeset

    defp put_verified_changes(changeset, verified) do
      verified.identifiers
      |> Enum.reduce(changeset, fn {field, value}, cs ->
        Ecto.Changeset.put_change(cs, field, value)
      end)
      |> Ecto.Changeset.put_change(:last_attested_cert_serial, verified.last_attested_cert_serial)
      |> Ecto.Changeset.put_change(:last_attested_cert_fingerprint, verified.last_attested_cert_fingerprint)
      |> Ecto.Changeset.put_change(:last_attested_at, DateTime.utc_now())
    end

    # Unconditional: an identity conflict must clear the verified fields even
    # when they arrived on the changeset rather than via `verified` (the
    # dormant unattested path), so a fallback insert can never collide with
    # the conflicting rows' unique indexes.
    defp strip_verified_changes(changeset) do
      Enum.reduce(@verified_fields, changeset, &Ecto.Changeset.delete_change(&2, &1))
    end

    # In-memory only, like merge_firezone_id: the verified identifiers and
    # pinned cert are persisted by the batched client session flush.
    # last_attested_at records when the device last proved possession; whether
    # the CURRENT session proved it is live connection state (the `attested?`
    # socket assign / presence attribute), not row state.
    defp merge_verified(client, nil), do: client

    defp merge_verified(client, verified) do
      client
      |> Map.merge(Map.new(verified.identifiers))
      |> Map.put(:last_attested_cert_serial, verified.last_attested_cert_serial)
      |> Map.put(:last_attested_cert_fingerprint, verified.last_attested_cert_fingerprint)
      |> Map.put(:last_attested_at, DateTime.utc_now())
    end

    defp find_by_firezone_id(_account_id, _actor_id, nil), do: nil

    defp find_by_firezone_id(account_id, actor_id, firezone_id) do
      from(d in Device,
        where: d.account_id == ^account_id,
        where: d.actor_id == ^actor_id,
        where: d.firezone_id == ^firezone_id,
        where: d.type == :client
      )
      |> Safe.unscoped(:replica)
      |> Safe.one(fallback_to_primary: true)
    end

    # The merge is in-memory only: the connect path stays write-free, and the
    # new firezone_id is persisted by the batched client session flush
    # (PortalAPI.Sockets.LatestSession) together with the rest of the
    # connect-time columns, so a reconnect storm (e.g. after a deploy or a
    # fleet-wide reinstall) never turns into a per-connect write storm.
    defp merge_firezone_id(client, firezone_id) do
      if is_nil(firezone_id) or client.firezone_id == firezone_id do
        client
      else
        %{client | firezone_id: firezone_id, firezone_id_merged?: true}
      end
    end

    defp check_hardware_id_mismatch(existing_client, attrs) do
      mismatched =
        Enum.filter(@hardware_id_fields, fn field ->
          existing_value = Map.get(existing_client, field)
          new_value = Map.get(attrs, to_string(field))

          not is_nil(existing_value) and not is_nil(new_value) and existing_value != new_value
        end)

      if mismatched != [] do
        details =
          Enum.flat_map(mismatched, fn field ->
            existing_value = Map.get(existing_client, field)
            new_value = Map.get(attrs, to_string(field))

            [{field, %{existing: existing_value, new: new_value}}]
          end)

        Logger.info(
          "Hardware ID mismatch for client",
          [client_id: existing_client.id] ++ details
        )
      end
    end
  end
end
