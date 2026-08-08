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
    unless Application.get_env(:portal, :sql_sandbox) do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Api)
    end

    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "client.connect" do
      with {:ok, token} <- PortalAPI.Sockets.extract_token(attrs, connect_info),
           :ok <- PortalAPI.Sockets.RateLimit.check(connect_info, token: token) do
        do_connect(token, attrs, socket, connect_info)
      end
    end
  end

  @impl true
  def id(socket) do
    Portal.Sockets.socket_id(socket.assigns.subject.credential.id)
  end

  ## Private functions

  defp do_connect(token, attrs, socket, connect_info) do
    context = PortalAPI.Sockets.auth_context(connect_info, :client)
    attrs = normalize_device_attrs(attrs)

    with {:ok, %{credential: %{type: :client_token, id: token_id}} = subject} <-
           Authentication.authenticate(token, context),
         false <- Portal.Billing.client_connect_restricted?(subject.account),
         {:ok, public_key} <- validate_public_key(attrs),
         changeset = insert_changeset(subject.actor, subject, attrs),
         {:ok, _} <- apply_action(changeset, :validate),
         {:ok, proof} <- attest_device(connect_info, subject),
         {:ok, client, attested?} <- Database.resolve_client(changeset, proof, subject) do
      version = derive_version(subject.context.user_agent)
      {context, version} = PortalAPI.Sockets.truncate_session_fields(subject.context, version)
      subject = %{subject | context: context}

      client = apply_session(client, token_id, public_key, subject, version)
      set_connect_attributes(token_id, client, subject, version)

      {:ok, assign_connect(socket, subject, client, version, attested?)}
    else
      {:error, :invalid_token} ->
        OpenTelemetry.Tracer.set_status(:error, "invalid_token")
        {:error, :invalid_token}

      true ->
        OpenTelemetry.Tracer.set_status(:error, "limits_exceeded")
        {:error, :limits_exceeded}

      {:error, :device_untrusted} ->
        OpenTelemetry.Tracer.set_status(:error, "device_untrusted")
        {:error, :device_untrusted}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset = public_socket_changeset(changeset)
        OpenTelemetry.Tracer.set_status(:error, inspect(changeset))
        Logger.debug("Error connecting client websocket: #{inspect(changeset)}")
        {:error, changeset}
    end
  end

  # Arriving on the mutual-TLS host is the client claiming it holds a device
  # certificate, so failing to prove one there refuses the connect instead of
  # silently downgrading to an unattested session. A connect on any other host
  # is unattested and carries on; whether that device may reach a given
  # resource is a policy question, not a socket one.
  defp attest_device(connect_info, subject) do
    case DeviceTrust.attest(connect_info, subject) do
      {:ok, proof} ->
        {:ok, proof}

      {:error, :not_attestation_host} ->
        {:ok, nil}

      {:error, reason} ->
        Logger.warning("Refusing client connect: device certificate is not trusted",
          account_id: subject.account.id,
          actor_id: subject.actor.id,
          reason: reason
        )

        {:error, :device_untrusted}
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

  defp assign_connect(socket, subject, client, version, attested?) do
    socket
    |> assign(:subject, subject)
    |> assign(:client, client)
    |> assign(:attested?, attested?)
    |> assign(:session_ref, make_ref())
    |> assign(:client_version, version)
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
    @attested_hardware_fields ~w[last_attested_device_serial last_attested_device_uuid]a
    @attested_id_fields @attested_hardware_fields ++ [:last_attested_mdm_device_id]
    @proof_fields @attested_id_fields ++ ~w[last_attested_cert_serial last_attested_cert_fingerprint last_attested_at]a

    @dialyzer {:no_opaque, [resolve_client: 3, find_by_attested_ids: 3]}

    # Resolves the connecting device. `proof` carries the attested identifiers
    # and pinned certificate from `PortalAPI.Client.DeviceTrust`, or nil for
    # unattested connects, in which case this behaves exactly like the classic
    # firezone_id find-or-create.
    #
    # A proof carrying an MDM device id resolves the row by certificate
    # identifiers alone: the client-supplied firezone_id neither selects a row
    # nor is persisted, so an attested device can never be pointed at a row it
    # did not prove ownership of. Its firezone_id column stays NULL, which the
    # partial unique index (client rows only, NULLs distinct) allows for any
    # number of rows.
    #
    # The third element says whether this connect's row actually took the
    # proven identity: a valid certificate does not vouch for a row whose
    # adoption was refused as a conflict.
    def resolve_client(changeset, proof, subject) do
      actor_id = Ecto.Changeset.get_field(changeset, :actor_id)
      firezone_id = Ecto.Changeset.get_field(changeset, :firezone_id)

      changeset = put_proof_changes(changeset, proof)

      case find_by_attested_ids(changeset, actor_id, subject) do
        {:ok, client} ->
          client = merge_hardware_ids(client, changeset)

          client =
            if attested_identity?(proof) do
              client |> clear_firezone_id() |> replace_proof(proof)
            else
              client |> merge_firezone_id(firezone_id) |> merge_proof(proof)
            end

          {:ok, client, not is_nil(proof)}

        :identity_conflict ->
          # Identity conflict - the identifiers split across rows, or a
          # matched row disagrees on another identifier: refuse to adopt any
          # attested identity for this connect and fall back to the plain
          # firezone_id path, keeping the proof fields off the row and off
          # the changeset so a fallback insert cannot collide with the
          # conflicting rows' unique indexes.
          changeset
          |> strip_proof_changes()
          |> resolve_by_firezone_id(actor_id, firezone_id, nil, subject)

        nil ->
          if attested_identity?(proof) do
            insert_attested(changeset, subject)
          else
            resolve_by_firezone_id(changeset, actor_id, firezone_id, proof, subject)
          end
      end
    end

    defp attested_identity?(nil), do: false
    defp attested_identity?(proof), do: attested_mdm_id?(proof.identifiers)

    defp attested_mdm_id?(identifiers),
      do: not is_nil(Map.get(identifiers, :last_attested_mdm_device_id))

    defp insert_attested(changeset, subject) do
      result =
        changeset
        |> Ecto.Changeset.put_change(:firezone_id, nil)
        |> Safe.scoped(subject)
        |> Safe.insert()

      with {:ok, client} <- result do
        {:ok, client, true}
      end
    end

    defp resolve_by_firezone_id(changeset, actor_id, firezone_id, proof, subject) do
      if client = find_by_firezone_id(actor_id, firezone_id, subject) do
        client = merge_hardware_ids(client, changeset)

        {client, attested?} =
          cond do
            is_nil(proof) ->
              {client, false}

            consistent_attested?(client, proof.identifiers) ->
              {merge_proof(client, proof), true}

            true ->
              log_attested_mismatch([client], proof.identifiers)
              {client, false}
          end

        {:ok, client, attested?}
      else
        with {:ok, client} <- changeset |> Safe.scoped(subject) |> Safe.insert() do
          {:ok, client, not is_nil(proof)}
        end
      end
    end

    # Attested identifiers anchor a physical device, so they take precedence
    # over the client-reported firezone_id: a reinstalled client (new
    # firezone_id, same attested identity) merges back onto its existing device
    # row instead of creating a duplicate. All supplied identifiers must
    # resolve to exactly one row (the per-column unique indexes guarantee each
    # identifier maps to at most one); identifiers split across rows are an
    # identity conflict. A certificate carrying the MDM device id then speaks
    # for the whole row. Without one, every identifier non-NULL on both the row
    # and the certificate must match.
    defp find_by_attested_ids(changeset, actor_id, subject) do
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
          where: d.actor_id == ^actor_id,
          where: d.type == :client,
          where: ^attested_match,
          order_by: [asc: d.inserted_at]
        )
        |> Safe.scoped(subject)
        |> Safe.all()
        |> classify_attested_rows(Map.new(filters))
      end
    end

    defp classify_attested_rows([], _cert_identifiers), do: nil

    defp classify_attested_rows([client], cert_identifiers) do
      if attested_mdm_id?(cert_identifiers) or consistent_attested?(client, cert_identifiers) do
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

    # Only the hardware identifiers have to agree. The MDM's device id is a
    # record id, not a property of the machine: it changes whenever the device
    # is re-enrolled, and the column is fed by whichever of intune-id /
    # entra-id / jamf-id / ws1-uuid / kandji-id the certificate happens to
    # list first. Treating either as a mismatch would strand a re-enrolled
    # device unattested forever, since the refusal also keeps the row from
    # ever learning the new value.
    defp consistent_attested?(client, cert_identifiers) do
      Enum.all?(@attested_hardware_fields, fn field ->
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

    defp put_proof_changes(changeset, nil), do: changeset

    defp put_proof_changes(changeset, proof) do
      proof.identifiers
      |> Enum.reduce(changeset, fn {field, value}, cs ->
        Ecto.Changeset.put_change(cs, field, value)
      end)
      |> Ecto.Changeset.put_change(:last_attested_cert_serial, proof.last_attested_cert_serial)
      |> Ecto.Changeset.put_change(:last_attested_cert_fingerprint, proof.last_attested_cert_fingerprint)
      |> Ecto.Changeset.put_change(:last_attested_at, DateTime.utc_now())
    end

    # Unconditional: an identity conflict must clear the proof fields even
    # when they arrived on the changeset rather than via `proof` (the
    # dormant unattested path), so a fallback insert can never collide with
    # the conflicting rows' unique indexes.
    defp strip_proof_changes(changeset) do
      Enum.reduce(@proof_fields, changeset, &Ecto.Changeset.delete_change(&2, &1))
    end

    # In-memory only, like merge_firezone_id: the proven identifiers and
    # pinned cert are persisted by the batched client session flush.
    # last_attested_at records when the device last proved possession; whether
    # the CURRENT session proved it is live connection state (the `attested?`
    # socket assign / presence attribute), not row state.
    # A certificate carrying the MDM device id is the authoritative statement of
    # what the device is, so identifiers it does not assert are cleared instead
    # of lingering from an older certificate.
    defp replace_proof(client, proof) do
      identifiers = Map.new(@attested_id_fields, &{&1, Map.get(proof.identifiers, &1)})

      client
      |> Map.merge(identifiers)
      |> put_pinned_cert(proof)
    end

    defp merge_proof(client, nil), do: client

    defp merge_proof(client, proof) do
      client
      |> Map.merge(Map.new(proof.identifiers))
      |> put_pinned_cert(proof)
    end

    defp put_pinned_cert(client, proof) do
      client
      |> Map.put(:last_attested_cert_serial, proof.last_attested_cert_serial)
      |> Map.put(:last_attested_cert_fingerprint, proof.last_attested_cert_fingerprint)
      |> Map.put(:last_attested_at, DateTime.utc_now())
    end

    defp find_by_firezone_id(_actor_id, nil, _subject), do: nil

    defp find_by_firezone_id(actor_id, firezone_id, subject) do
      from(d in Device,
        where: d.actor_id == ^actor_id,
        where: d.firezone_id == ^firezone_id,
        where: d.type == :client
      )
      |> Safe.scoped(subject)
      |> Safe.one()
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

    # Rows attested before this became the rule can still carry a firezone_id;
    # the flush clears the column for any entry with a proven MDM device id, so
    # they converge on their next connect.
    defp clear_firezone_id(client) do
      %{client | firezone_id: nil}
    end

    # The self-reported identifiers are whatever the client says it is today,
    # so every connect carries them and the flush coalesces: a field the client
    # omits keeps the row's current value rather than clearing it.
    defp merge_hardware_ids(client, changeset) do
      reported =
        Map.new(@hardware_id_fields, fn field ->
          {field, Ecto.Changeset.get_field(changeset, field)}
        end)

      Map.merge(client, reported, fn _field, current, reported ->
        reported || current
      end)
    end
  end
end
