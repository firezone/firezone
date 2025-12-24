defmodule PortalAPI.Relay.Socket do
  use Phoenix.Socket
  import Ecto.Changeset
  import Portal.Changeset
  alias Portal.{Auth, Version, Relay}
  alias __MODULE__.DB
  require Logger
  require OpenTelemetry.Tracer

  ## Channels

  channel "relay", PortalAPI.Relay.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => encoded_token} = attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "relay.connect" do
      context = PortalAPI.Sockets.auth_context(connect_info, :relay)
      attrs = Map.take(attrs, ~w[ipv4 ipv6 name port])

      with {:ok, relay_token} <- Auth.verify_relay_token(encoded_token),
           {:ok, relay} <- upsert_relay(attrs, context) do
        OpenTelemetry.Tracer.set_attributes(%{
          token_id: relay_token.id,
          relay_id: relay.id,
          version: relay.last_seen_version
        })

        socket =
          socket
          |> assign(:token_id, relay_token.id)
          |> assign(:relay, relay)
          |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
          |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())

        {:ok, socket}
      else
        error ->
          trace = Process.info(self(), :current_stacktrace)
          Logger.info("Relay socket connection failed", error: error, stacktrace: trace)

          error
      end
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :missing_token}
  end

  @impl true
  def id(socket), do: Portal.Sockets.socket_id(socket.assigns.token_id)

  defp upsert_relay(attrs, %Auth.Context{} = context) do
    changeset = upsert_changeset(attrs, context)
    DB.upsert_relay(changeset)
  end

  defp upsert_changeset(attrs, %Auth.Context{} = context) do
    upsert_fields = ~w[ipv4 ipv6 port name
                       last_seen_user_agent
                       last_seen_remote_ip
                       last_seen_remote_ip_location_region
                       last_seen_remote_ip_location_city
                       last_seen_remote_ip_location_lat
                       last_seen_remote_ip_location_lon]a

    %Relay{}
    |> cast(attrs, upsert_fields)
    |> validate_required_one_of(~w[ipv4 ipv6]a)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:port, greater_than_or_equal_to: 1, less_than_or_equal_to: 65_535)
    |> unique_constraint(:ipv4, name: :relays_unique_address_index)
    |> unique_constraint(:ipv6, name: :relays_unique_address_index)
    |> unique_constraint(:port, name: :relays_unique_address_index)
    |> unique_constraint(:ipv4, name: :global_relays_unique_address_index)
    |> unique_constraint(:ipv6, name: :global_relays_unique_address_index)
    |> unique_constraint(:port, name: :global_relays_unique_address_index)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> put_change(:last_seen_user_agent, context.user_agent)
    |> put_change(:last_seen_remote_ip, context.remote_ip)
    |> put_change(:last_seen_remote_ip_location_region, context.remote_ip_location_region)
    |> put_change(:last_seen_remote_ip_location_city, context.remote_ip_location_city)
    |> put_change(:last_seen_remote_ip_location_lat, context.remote_ip_location_lat)
    |> put_change(:last_seen_remote_ip_location_lon, context.remote_ip_location_lon)
    |> put_relay_version()
  end

  defp put_relay_version(changeset) do
    with {_data_or_changes, user_agent} when not is_nil(user_agent) <-
           fetch_field(changeset, :last_seen_user_agent),
         {:ok, version} <- Version.fetch_version(user_agent) do
      put_change(changeset, :last_seen_version, version)
    else
      {:error, :invalid_user_agent} -> add_error(changeset, :last_seen_user_agent, "is invalid")
      _ -> changeset
    end
  end

  defmodule DB do
    alias Portal.Safe

    def upsert_relay(changeset) do
      conflict_target = {:unsafe_fragment, ~s/(COALESCE(ipv4, ipv6), port)/}

      conflict_replace_fields =
        ~w[ipv4 ipv6 port name
         last_seen_user_agent
         last_seen_remote_ip
         last_seen_remote_ip_location_region
         last_seen_remote_ip_location_city
         last_seen_remote_ip_location_lat
         last_seen_remote_ip_location_lon
         last_seen_version
         last_seen_at
         updated_at]a

      on_conflict = {:replace, conflict_replace_fields}

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:relay, changeset,
        conflict_target: conflict_target,
        on_conflict: on_conflict,
        returning: true
      )
      |> Safe.transact()
      |> case do
        {:ok, %{relay: relay}} -> {:ok, relay}
        {:error, :relay, changeset, _effects_so_far} -> {:error, changeset}
      end
    end
  end
end
