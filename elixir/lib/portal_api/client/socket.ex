defmodule PortalAPI.Client.Socket do
  use Phoenix.Socket
  alias Portal.{Authentication, Device, PG, SessionLog, Version}
  alias Portal.Repo.Batch
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
      Portal.Repo.Replica.put_dynamic_repo(Portal.Repo.Replica.Api)
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
         {:ok, client} <- Database.find_or_create_client(changeset, attrs) do
      version = derive_version(subject.context.user_agent)
      {context, version} = PortalAPI.Sockets.truncate_session_fields(subject.context, version)
      subject = %{subject | context: context}
      client = apply_session(client, token_id, public_key, subject, version)
      set_connect_attributes(token_id, client, subject, version)
      {:ok, assign_connect(socket, subject, client, version)}
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
    {persisted, failed} = Sockets.LatestSession.upsert_all(entries, :client_token_id)

    failed_conn_ids = MapSet.new(failed, fn {attrs, _metadata} -> attrs.conn_id end)

    for {attrs, _metadata} <- failed do
      dispatch_queue_callback("client session", :on_failed, attrs, fn ->
        PG.deliver(attrs.device_id, :disconnect)
      end)
    end

    # Durability is confirmed only once both the device upsert and the log have
    # landed: a session whose log write fails is left unconfirmed so its
    # durability timer fires and the client reconnects to retry both. This
    # keeps the session log fail-closed without a transaction spanning the
    # upsert and the log insert.
    log_failed_conn_ids = insert_session_logs(entries, failed_conn_ids)
    dispatch_client_session_confirmed(entries, MapSet.union(failed_conn_ids, log_failed_conn_ids))

    if failed != [] do
      Logger.info(
        "Skipped #{length(failed)} client session entries during flush due to deleted devices or tokens"
      )
    end

    persisted
  end

  defp dispatch_client_session_confirmed(entries, failed_conn_ids) do
    for {attrs, _metadata} <- entries, not MapSet.member?(failed_conn_ids, attrs.conn_id) do
      dispatch_queue_callback("client session", :on_confirmed, attrs, fn ->
        PG.deliver(attrs.device_id, {:confirm_session_durability, attrs.conn_id})
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
  # whole batch. Each log entry carries its conn_id so the caller can learn
  # which sessions' logs failed and withhold their durability confirmation.
  defp insert_session_logs(entries, failed_conn_ids) do
    log_entries =
      for {attrs, metadata} <- entries, not MapSet.member?(failed_conn_ids, attrs.conn_id) do
        {session_log_attrs(attrs, metadata), attrs.conn_id}
      end

    {_inserted, failed} =
      Batch.insert_all(SessionLog, log_entries,
        label: "client session log",
        fk_partitions: %{
          "session_logs_account_id_fkey" => {:simple, :account_id, Portal.Account}
        }
      )

    MapSet.new(failed, fn {_log_attrs, conn_id} -> conn_id end)
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
        "Queue #{label} #{callback} crashed for entry #{inspect(attrs[:conn_id])}: " <>
          Exception.message(error)
      )
  catch
    kind, reason ->
      Logger.error(
        "Queue #{label} #{callback} threw #{kind} for entry #{inspect(attrs[:conn_id])}: " <>
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
    |> assign(:conn_id, make_ref())
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

    @dialyzer {:no_opaque, [find_or_create_client: 2]}
    def find_or_create_client(changeset, attrs) do
      account_id = Ecto.Changeset.get_field(changeset, :account_id)
      actor_id = Ecto.Changeset.get_field(changeset, :actor_id)
      firezone_id = Ecto.Changeset.get_field(changeset, :firezone_id)

      existing =
        if firezone_id do
          from(d in Device,
            where: d.account_id == ^account_id,
            where: d.actor_id == ^actor_id,
            where: d.firezone_id == ^firezone_id,
            where: d.type == :client
          )
          |> Safe.unscoped(:replica)
          |> Safe.one(fallback_to_primary: true)
        end

      if existing do
        check_hardware_id_mismatch(existing, attrs)
        {:ok, existing}
      else
        changeset
        |> Safe.unscoped()
        |> Safe.insert()
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
