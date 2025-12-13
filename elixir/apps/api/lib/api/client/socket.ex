defmodule API.Client.Socket do
  use Phoenix.Socket
  alias Domain.{Auth, Version}
  alias Domain.Client
  alias __MODULE__.DB
  require Logger
  require OpenTelemetry.Tracer
  import Ecto.Changeset
  import Domain.Changeset

  ## Channels

  channel "client", API.Client.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => token} = attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "client.connect" do
      context = API.Sockets.auth_context(connect_info, :client)

      with {:ok, %{auth_ref: %{type: :token, id: token_id}} = subject} <-
             Auth.authenticate(token, context),
           changeset = upsert_changeset(subject.actor, subject, attrs),
           {:ok, client} <- DB.upsert_client(changeset, subject) do
        OpenTelemetry.Tracer.set_attributes(%{
          token_id: token_id,
          client_id: client.id,
          lat: client.last_seen_remote_ip_location_lat,
          lon: client.last_seen_remote_ip_location_lon,
          version: client.last_seen_version,
          account_id: subject.account.id
        })

        socket =
          socket
          |> assign(:subject, subject)
          |> assign(:client, client)
          |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
          |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())

        {:ok, socket}
      else
        {:error, :unauthorized} ->
          OpenTelemetry.Tracer.set_status(:error, "unauthorized")
          {:error, :invalid_token}

        {:error, reason} ->
          OpenTelemetry.Tracer.set_status(:error, inspect(reason))
          Logger.debug("Error connecting client websocket: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :missing_token}
  end

  @impl true

  def id(socket) do
    Domain.Sockets.socket_id(socket.assigns.subject.auth_ref.id)
  end

  defp upsert_changeset(actor, subject, attrs) do
    required_fields = ~w[external_id name public_key]a

    hardware_identifiers =
      ~w[device_serial device_uuid identifier_for_vendor firebase_installation_id]a

    upsert_fields = required_fields ++ hardware_identifiers

    %Client{}
    |> cast(attrs, upsert_fields)
    |> put_default_value(:name, &generate_name/0)
    |> put_change(:actor_id, actor.id)
    |> put_change(:account_id, actor.account_id)
    |> put_change(:last_seen_user_agent, subject.context.user_agent)
    |> put_change(:last_seen_remote_ip, %Postgrex.INET{address: subject.context.remote_ip})
    |> put_change(:last_seen_remote_ip_location_region, subject.context.remote_ip_location_region)
    |> put_change(:last_seen_remote_ip_location_city, subject.context.remote_ip_location_city)
    |> put_change(:last_seen_remote_ip_location_lat, subject.context.remote_ip_location_lat)
    |> put_change(:last_seen_remote_ip_location_lon, subject.context.remote_ip_location_lon)
    |> validate_required(required_fields)
    |> Domain.Client.changeset()
    |> validate_base64(:public_key)
    |> validate_length(:public_key, is: 44)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> put_client_version()
  end

  def finalize_upsert(%Client{} = client, ipv4, ipv6) do
    import Ecto.Changeset

    client
    |> change()
    |> put_change(:ipv4, ipv4)
    |> put_change(:ipv6, ipv6)
    |> Domain.Client.changeset()
  end

  defp put_client_version(changeset) do
    import Ecto.Changeset

    with {_data_or_changes, user_agent} when not is_nil(user_agent) <-
           Ecto.Changeset.fetch_field(changeset, :last_seen_user_agent),
         {:ok, version} <- Version.fetch_version(user_agent) do
      put_change(changeset, :last_seen_version, version)
    else
      {:error, :invalid_user_agent} -> add_error(changeset, :last_seen_user_agent, "is invalid")
      _ -> changeset
    end
  end

  defp generate_name do
    name = Domain.NameGenerator.generate()

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

  defmodule DB do
    import Ecto.Query
    alias Domain.{Safe, Network}
    alias Domain.Client

    def upsert_client(changeset, _subject) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:client, changeset,
        conflict_target: upsert_conflict_target(),
        on_conflict: upsert_on_conflict(),
        returning: true
      )
      |> resolve_address_multi(:ipv4)
      |> resolve_address_multi(:ipv6)
      |> Ecto.Multi.update(:client_with_address, fn
        %{client: %Client{} = client, ipv4: ipv4, ipv6: ipv6} ->
          API.Client.Socket.finalize_upsert(client, ipv4, ipv6)
      end)
      |> Safe.transact()
      |> case do
        {:ok, %{client_with_address: client}} -> {:ok, client}
        {:error, :client, changeset, _effects_so_far} -> {:error, changeset}
      end
    end

    defp upsert_conflict_target do
      {:unsafe_fragment, ~s/(account_id, actor_id, external_id)/}
    end

    defp upsert_on_conflict do
      from(c in Client, as: :clients)
      |> update([clients: clients],
        set: [
          public_key: fragment("EXCLUDED.public_key"),
          last_seen_user_agent: fragment("EXCLUDED.last_seen_user_agent"),
          last_seen_remote_ip: fragment("EXCLUDED.last_seen_remote_ip"),
          last_seen_remote_ip_location_region:
            fragment("EXCLUDED.last_seen_remote_ip_location_region"),
          last_seen_remote_ip_location_city:
            fragment("EXCLUDED.last_seen_remote_ip_location_city"),
          last_seen_remote_ip_location_lat: fragment("EXCLUDED.last_seen_remote_ip_location_lat"),
          last_seen_remote_ip_location_lon: fragment("EXCLUDED.last_seen_remote_ip_location_lon"),
          last_seen_version: fragment("EXCLUDED.last_seen_version"),
          last_seen_at: fragment("EXCLUDED.last_seen_at"),
          device_serial: fragment("EXCLUDED.device_serial"),
          device_uuid: fragment("EXCLUDED.device_uuid"),
          identifier_for_vendor: fragment("EXCLUDED.identifier_for_vendor"),
          firebase_installation_id: fragment("EXCLUDED.firebase_installation_id"),
          updated_at: fragment("timezone('UTC', NOW())"),
          verified_at:
            fragment(
              """
              CASE WHEN (EXCLUDED.device_serial = ?.device_serial OR ?.device_serial IS NULL)
                    AND (EXCLUDED.device_uuid = ?.device_uuid OR ?.device_uuid IS NULL)
                    AND (EXCLUDED.identifier_for_vendor = ?.identifier_for_vendor OR ?.identifier_for_vendor IS NULL)
                    AND (EXCLUDED.firebase_installation_id = ?.firebase_installation_id OR ?.firebase_installation_id IS NULL)
                   THEN ?
                   ELSE NULL
              END
              """,
              clients,
              clients,
              clients,
              clients,
              clients,
              clients,
              clients,
              clients,
              clients.verified_at
            )
        ]
      )
    end

    defp resolve_address_multi(multi, type) do
      Ecto.Multi.run(multi, type, fn _repo, %{client: %Client{} = client} ->
        if address = Map.get(client, type) do
          {:ok, address}
        else
          {:ok, Network.fetch_next_available_address!(client.account_id, type)}
        end
      end)
    end
  end
end
