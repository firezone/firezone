defmodule PortalAPI.Client.Socket do
  use Phoenix.Socket
  alias Portal.Authentication.Credential
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

  @certificate_authentication_errors [
    :certificate_revoked,
    :invalid_certificate,
    :invalid_x509_identity,
    :malformed_cert_issuer,
    :malformed_cert_serial,
    :missing_client_auth_eku,
    :missing_digital_signature_key_usage,
    :no_device_identifiers,
    :no_trust_anchors,
    :outside_validity_window,
    :untrusted_chain,
    :x509_account_disabled,
    :x509_account_not_found,
    :x509_authentication_disabled,
    :x509_authentication_not_found,
    :x509_user_disabled,
    :x509_user_not_authorized,
    :x509_user_not_found,
    :x509_user_type_not_allowed
  ]

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
      context = PortalAPI.Sockets.auth_context(connect_info, :client)
      attrs = normalize_device_attrs(attrs)

      case DeviceTrust.prepare_authentication(connect_info) do
        {:ok, authentication} ->
          authenticate_with_certificate(authentication, context, attrs, socket, connect_info)

        {:error, :not_x509_identity} ->
          connect_with_token(context, attrs, socket, connect_info)

        {:error, reason} ->
          handle_certificate_authentication_error(reason)
      end
    end
  end

  @impl true
  def id(socket) do
    Portal.Sockets.socket_id(socket.assigns.subject.credential.id)
  end

  ## Private functions

  defp authenticate_with_certificate(authentication, context, attrs, socket, connect_info) do
    # The fixed discriminator makes this an IP-only bucket. The bearer header
    # is irrelevant once X.509 identity claims are present, so allowing it to
    # vary the key would let a caller evade this pre-authentication limit.
    with :ok <- PortalAPI.Sockets.RateLimit.check(connect_info, token: "x509"),
         {:ok, subject, proof} <- DeviceTrust.authenticate(authentication, context) do
      do_connect(subject, nil, proof, attrs, socket)
    else
      {:error, :not_x509_identity} ->
        connect_with_token(context, attrs, socket, connect_info)

      {:error, :rate_limit} = error ->
        error

      {:error, reason} ->
        handle_certificate_authentication_error(reason)
    end
  end

  defp connect_with_token(context, attrs, socket, connect_info) do
    with {:ok, token} <- PortalAPI.Sockets.extract_token(attrs, connect_info),
         :ok <- PortalAPI.Sockets.RateLimit.check(connect_info, token: token),
         {:ok, %{credential: %Credential.ClientToken{id: token_id}} = subject} <-
           Authentication.authenticate(token, context) do
      do_connect(subject, token_id, nil, attrs, socket, connect_info)
    else
      {:error, :invalid_token} ->
        OpenTelemetry.Tracer.set_status(:error, "invalid_token")
        {:error, :invalid_token}

      error ->
        error
    end
  end

  defp do_connect(subject, token_id, proof, attrs, socket, connect_info \\ nil) do
    with false <- Portal.Billing.client_connect_restricted?(subject.account),
         {:ok, public_key} <- validate_public_key(attrs),
         changeset = insert_changeset(subject.actor, subject, attrs),
         {:ok, _} <- apply_action(changeset, :validate),
         {:ok, proof} <- attest_device(proof, connect_info, subject),
         {:ok, client, attested?} <- Database.resolve_client(changeset, proof, subject) do
      version = derive_version(subject.context.user_agent)
      {context, version} = PortalAPI.Sockets.truncate_session_fields(subject.context, version)
      subject = %{subject | context: context}

      client = apply_session(client, token_id, public_key, subject, version)
      set_connect_attributes(token_id, client, subject, version)

      {:ok, assign_connect(socket, subject, client, version, attested?, proof)}
    else
      true ->
        OpenTelemetry.Tracer.set_status(:error, "limits_exceeded")
        {:error, :limits_exceeded}

      {:error, :device_untrusted} ->
        OpenTelemetry.Tracer.set_status(:error, "device_untrusted")
        {:error, :device_untrusted}

      {:error, :device_identity_conflict} ->
        OpenTelemetry.Tracer.set_status(:error, "device_identity_conflict")
        {:error, :device_identity_conflict}

      {:error, :certificate_revoked} ->
        OpenTelemetry.Tracer.set_status(:error, "certificate_revoked")
        {:error, :certificate_revoked}

      {:error, %Ecto.Changeset{} = changeset} ->
        changeset = public_socket_changeset(changeset)
        OpenTelemetry.Tracer.set_status(:error, inspect(changeset))
        Logger.debug("Error connecting client websocket: #{inspect(changeset)}")
        {:error, changeset}
    end
  end

  defp handle_certificate_authentication_error(reason)
       when reason in @certificate_authentication_errors do
    Logger.warning("Refusing client connect: X.509 authentication failed", reason: reason)
    OpenTelemetry.Tracer.set_status(:error, Atom.to_string(reason))
    {:error, reason}
  end

  defp handle_certificate_authentication_error(reason) do
    Logger.warning("Refusing client connect: X.509 authentication failed", reason: reason)
    OpenTelemetry.Tracer.set_status(:error, "device_untrusted")
    {:error, :device_untrusted}
  end

  # Arriving on the mutual-TLS host is the client claiming it holds a device
  # certificate, so failing to prove one there refuses the connect instead of
  # silently downgrading to an unattested session. A connect on any other host
  # is unattested and carries on; whether that device may reach a given
  # resource is a policy question, not a socket one.
  defp attest_device(%{} = proof, _connect_info, _subject), do: {:ok, proof}

  defp attest_device(nil, connect_info, subject) do
    case DeviceTrust.attest(connect_info, subject) do
      {:ok, proof} ->
        {:ok, proof}

      {:error, :not_attestation_host} ->
        {:ok, nil}

      # Kept distinct from a certificate that never verified: the device holds a
      # genuine certificate its CA has withdrawn, and saying so is what tells an
      # administrator to reissue rather than to check the deployment.
      {:error, :certificate_revoked} ->
        Logger.warning("Refusing client connect: device certificate was revoked",
          account_id: subject.account.id,
          actor_id: subject.actor.id
        )

        {:error, :certificate_revoked}

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
    attributes = %{
      client_id: client.id,
      lat: subject.context.remote_ip_location_lat,
      lon: subject.context.remote_ip_location_lon,
      version: version,
      account_id: subject.account.id
    }

    attributes = if token_id, do: Map.put(attributes, :token_id, token_id), else: attributes
    OpenTelemetry.Tracer.set_attributes(attributes)
  end

  defp assign_connect(socket, subject, client, version, attested?, proof) do
    socket
    |> assign(:subject, subject)
    |> assign(:client, %{client | attested?: attested?, posture: posture_rows(client, subject)})
    |> assign(:attestation, attestation(attested?, proof))
    |> assign(:session_ref, make_ref())
    |> assign(:client_version, version)
    |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
    |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())
  end

  defp posture_rows(client, subject) do
    if Portal.Account.device_posture_enabled?(subject.account) do
      Portal.Devices.Posture.rows_by_type(client)
    else
      %{}
    end
  end

  # The certificate this session is riding on, so a revocation learned later can
  # be matched against the connection rather than against the device's history.
  # A device that attested last week but connected without a certificate today
  # holds nothing here, and a revocation of that old certificate leaves it alone.
  defp attestation(true, %{} = proof) do
    %{issuer: proof.last_attested_cert_issuer, serial: proof.last_attested_cert_serial}
  end

  defp attestation(_attested?, _proof), do: nil

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

    @dialyzer {:no_opaque, [resolve_client: 3]}

    # Resolves the connecting device. `proof` carries the attested identifiers
    # and pinned certificate from `PortalAPI.Client.DeviceTrust`, or nil for
    # unattested connects.
    #
    # The two are entirely separate. An attested connect resolves only by what
    # its certificate proves and never touches the client-supplied firezone_id,
    # so a device holding a certificate can never be pointed at a row it did
    # not prove ownership of. Its firezone_id column is left NULL, which the
    # partial unique index (client rows only, NULLs distinct) allows for any
    # number of rows. An unattested connect is the classic firezone_id
    # find-or-create and never reads or writes an attested field.
    #
    # The third element says whether this connect proved a device identity.
    def resolve_client(changeset, proof, subject) do
      actor_id = Ecto.Changeset.get_field(changeset, :actor_id)

      if is_nil(proof) do
        firezone_id = Ecto.Changeset.get_field(changeset, :firezone_id)
        resolve_unattested(changeset, actor_id, firezone_id, subject)
      else
        changeset
        |> put_proof_changes(proof)
        |> resolve_attested(proof, subject)
      end
    end

    # The row and how it was matched both come from the attestation read, which
    # resolves identity in the same statement that checks the certificate for
    # revocation. A device that re-enrolls arrives with a new MDM device id and
    # gets a new row: the hardware identifiers it might otherwise be relocated
    # by are self-reported at enrollment, and Microsoft documents them as
    # spoofable by anyone with access to the device.
    defp resolve_attested(changeset, proof, subject) do
      case proof.device do
        nil -> insert_attested(changeset, subject)
        client -> adopt_attested(client, changeset, proof, proof.matched_on)
      end
    end

    # The row this resolves to is this device by definition. The hardware
    # identifiers are attributes that follow the certificate: it may start
    # asserting one the row lacks, or stop asserting one the row has, since
    # which identifiers an MDM emits is a profile setting an admin can change
    # at any time. Only a value present on both sides and disagreeing is a
    # contradiction, and it means one identity covers two physical machines,
    # with no safe way to tell which one is connecting.
    defp adopt_attested(client, changeset, proof, matched_on) do
      case contradicted_attested_ids(client, proof.identifiers, matched_on) do
        [] ->
          client =
            client
            |> merge_hardware_ids(changeset)
            |> clear_firezone_id()
            |> replace_proof(proof)

          {:ok, client, true}

        contradicted ->
          Logger.error(
            "Attested hardware identifier contradicts the device row: refusing the connect",
            client_id: client.id,
            contradicted: inspect(contradicted),
            cert_identifiers: inspect(proof.identifiers),
            row_identifiers: inspect(Map.take(client, @attested_id_fields))
          )

          {:error, :device_identity_conflict}
      end
    end

    # Every identifier the certificate asserts, not only the hardware ones. On
    # the MDM device id this is trivially satisfied when that is what found the
    # row. It earns its place on the pinned-certificate path.
    #
    # What counts as a disagreement depends on which identifier found the row.
    # A certificate reached by its MDM device id is a different certificate from
    # the one the row was written by, so an identifier appearing or disappearing
    # is a profile that changed what it emits, and the row follows.
    #
    # A certificate reached by its issuer and serial is the same certificate.
    # Its identifiers cannot have changed, so anything but an exact match means
    # we read the same bytes differently than we did before. That is a bug in
    # the reading, and the connect is refused rather than letting a worse read
    # rewrite the row. Fixing the reading is what repairs those rows.
    defp contradicted_attested_ids(client, cert_identifiers, matched_on) do
      Enum.filter(@attested_id_fields, fn field ->
        row_value = Map.get(client, field)
        cert_value = Map.get(cert_identifiers, field)

        contradicts?(row_value, cert_value, matched_on)
      end)
    end

    defp contradicts?(row_value, cert_value, :cert_identity), do: row_value != cert_value
    defp contradicts?(nil, _cert_value, :mdm_device_id), do: false
    defp contradicts?(_row_value, nil, :mdm_device_id), do: false
    defp contradicts?(row_value, cert_value, :mdm_device_id), do: row_value != cert_value

    defp resolve_unattested(changeset, actor_id, firezone_id, subject) do
      if client = find_by_firezone_id(actor_id, firezone_id, subject) do
        {:ok, merge_hardware_ids(client, changeset), false}
      else
        with {:ok, client} <- changeset |> Safe.scoped(subject) |> Safe.insert() do
          {:ok, client, false}
        end
      end
    end

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

    defp put_proof_changes(changeset, proof) do
      proof.identifiers
      |> Enum.reduce(changeset, fn {field, value}, cs ->
        Ecto.Changeset.put_change(cs, field, value)
      end)
      |> Ecto.Changeset.put_change(:last_attested_cert_serial, proof.last_attested_cert_serial)
      |> Ecto.Changeset.put_change(
        :last_attested_cert_fingerprint,
        proof.last_attested_cert_fingerprint
      )
      |> Ecto.Changeset.put_change(:last_attested_cert_issuer, proof.last_attested_cert_issuer)
      |> Ecto.Changeset.put_change(:last_attested_at, DateTime.utc_now())
    end

    defp replace_proof(client, proof) do
      identifiers = Map.new(@attested_id_fields, &{&1, Map.get(proof.identifiers, &1)})

      client
      |> Map.merge(identifiers)
      |> put_pinned_cert(proof)
    end

    defp put_pinned_cert(client, proof) do
      client
      |> Map.put(:last_attested_cert_serial, proof.last_attested_cert_serial)
      |> Map.put(:last_attested_cert_fingerprint, proof.last_attested_cert_fingerprint)
      |> Map.put(:last_attested_cert_issuer, proof.last_attested_cert_issuer)
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
