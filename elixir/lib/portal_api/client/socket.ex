defmodule PortalAPI.Client.Socket do
  use Phoenix.Socket
  alias Portal.{Authentication, ClientSession, Version}
  alias Portal.Client
  alias __MODULE__.Database
  require Logger
  require OpenTelemetry.Tracer
  import Ecto.Changeset
  import Portal.Changeset

  ## Channels

  channel "client", PortalAPI.Client.Channel

  ## Authentication

  @impl true
  def connect(attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "client.connect" do
      with :ok <- PortalAPI.Sockets.RateLimit.check(connect_info),
           {:ok, token} <- PortalAPI.Sockets.extract_token(attrs, connect_info) do
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

    with {:ok, %{credential: %{type: :client_token, id: token_id}} = subject} <-
           Authentication.authenticate(token, context),
         false <- Portal.Billing.client_connect_restricted?(subject.account),
         {:ok, public_key} <- validate_public_key(attrs),
         changeset = insert_changeset(subject.actor, subject, attrs),
         {:ok, client} <- Database.find_or_create_client(changeset, attrs) do
      version = derive_version(subject.context.user_agent)
      session = build_session(client, token_id, public_key, subject, version)
      Portal.ClientSession.Buffer.insert(session)
      set_connect_attributes(token_id, client, subject, version)
      {:ok, assign_connect(socket, subject, client, session, version)}
    else
      {:error, :unauthorized} ->
        OpenTelemetry.Tracer.set_status(:error, "unauthorized")
        {:error, :invalid_token}

      true ->
        OpenTelemetry.Tracer.set_status(:error, "limits_exceeded")
        {:error, :limits_exceeded}

      {:error, reason} ->
        OpenTelemetry.Tracer.set_status(:error, inspect(reason))
        Logger.debug("Error connecting client websocket: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_session(client, token_id, public_key, subject, version) do
    %ClientSession{
      client_id: client.id,
      account_id: client.account_id,
      client_token_id: token_id,
      public_key: public_key,
      user_agent: subject.context.user_agent,
      remote_ip: subject.context.remote_ip,
      remote_ip_location_region: subject.context.remote_ip_location_region,
      remote_ip_location_city: subject.context.remote_ip_location_city,
      remote_ip_location_lat: subject.context.remote_ip_location_lat,
      remote_ip_location_lon: subject.context.remote_ip_location_lon,
      version: version
    }
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

  defp assign_connect(socket, subject, client, session, version) do
    socket
    |> assign(:subject, subject)
    |> assign(:client, client)
    |> assign(:session, session)
    |> assign(:client_version, version)
    |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
    |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())
  end

  defp insert_changeset(actor, subject, attrs) do
    required_fields = ~w[external_id name]a

    hardware_identifiers =
      ~w[device_serial device_uuid identifier_for_vendor firebase_installation_id]a

    insert_fields = required_fields ++ hardware_identifiers

    %Client{}
    |> cast(attrs, insert_fields)
    |> put_default_value(:name, &generate_name/0)
    |> put_change(:actor_id, actor.id)
    |> put_change(:account_id, actor.account_id)
    |> validate_required(required_fields)
    |> Portal.Client.changeset()
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

  defp derive_version(user_agent) when is_binary(user_agent) do
    case Version.fetch_version(user_agent) do
      {:ok, version} -> version
      _ -> nil
    end
  end

  defp derive_version(_), do: nil

  ## Database

  defmodule Database do
    import Ecto.Query
    alias Portal.Client
    alias Portal.IPv4Address
    alias Portal.IPv6Address
    alias Portal.Safe
    require Logger

    @hardware_id_fields ~w[device_serial device_uuid identifier_for_vendor firebase_installation_id]a

    @dialyzer {:no_opaque, [find_or_create_client: 2, insert_new_client: 2]}
    def find_or_create_client(changeset, attrs) do
      account_id = Ecto.Changeset.get_field(changeset, :account_id)
      actor_id = Ecto.Changeset.get_field(changeset, :actor_id)
      external_id = Ecto.Changeset.get_field(changeset, :external_id)

      existing =
        if external_id do
          from(c in Client,
            where: c.account_id == ^account_id,
            where: c.actor_id == ^actor_id,
            where: c.external_id == ^external_id,
            preload: [:ipv4_address, :ipv6_address]
          )
          |> Safe.unscoped(:replica)
          |> Safe.one(fallback_to_primary: true)
        end

      if existing do
        check_hardware_id_mismatch(existing, attrs)
        {:ok, existing}
      else
        insert_new_client(changeset, account_id)
      end
    end

    defp insert_new_client(changeset, account_id) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:client, changeset)
      |> Ecto.Multi.run(:ipv4_address, fn _repo, %{client: client} ->
        IPv4Address.allocate_next_available_address(account_id, client_id: client.id)
      end)
      |> Ecto.Multi.run(:ipv6_address, fn _repo, %{client: client} ->
        IPv6Address.allocate_next_available_address(account_id, client_id: client.id)
      end)
      |> Safe.transact()
      |> case do
        {:ok, %{client: client, ipv4_address: ipv4_address, ipv6_address: ipv6_address}} ->
          {:ok, %{client | ipv4_address: ipv4_address, ipv6_address: ipv6_address}}

        {:error, :client, changeset, _effects_so_far} ->
          {:error, changeset}
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

        Logger.warning(
          "Hardware ID mismatch for client",
          [client_id: existing_client.id] ++ details
        )
      end
    end
  end
end
