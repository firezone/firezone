defmodule API.Gateway.Socket do
  use Phoenix.Socket
  alias Domain.{Tokens, Gateways, Gateway, Version}
  alias __MODULE__.DB
  require Logger
  require OpenTelemetry.Tracer

  ## Channels

  channel "gateway", API.Gateway.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => encoded_token} = attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "gateway.connect" do
      context = API.Sockets.auth_context(connect_info, :gateway_group)
      attrs = Map.take(attrs, ~w[external_id name public_key])

      with {:ok, group, token} <- Gateways.authenticate(encoded_token, context),
           changeset = upsert_changeset(group, attrs, context),
           {:ok, gateway} <- DB.upsert_gateway(changeset, group) do
        OpenTelemetry.Tracer.set_attributes(%{
          token_id: token.id,
          gateway_id: gateway.id,
          account_id: gateway.account_id,
          version: gateway.last_seen_version
        })

        socket =
          socket
          |> assign(:token_id, token.id)
          |> assign(:gateway_group, group)
          |> assign(:gateway, gateway)
          |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
          |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())

        {:ok, socket}
      else
        {:error, :unauthorized} ->
          OpenTelemetry.Tracer.set_status(:error, "invalid_token")
          {:error, :invalid_token}

        {:error, reason} ->
          OpenTelemetry.Tracer.set_status(:error, inspect(reason))
          Logger.debug("Error connecting gateway websocket: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :missing_token}
  end

  @impl true
  def id(socket), do: Tokens.socket_id(socket.assigns.token_id)

  defp upsert_changeset(group, attrs, context) do
    import Ecto.Changeset
    import Domain.Repo.Changeset
    
    upsert_fields = ~w[external_id name public_key
                      last_seen_user_agent
                      last_seen_remote_ip
                      last_seen_remote_ip_location_region
                      last_seen_remote_ip_location_city
                      last_seen_remote_ip_location_lat
                      last_seen_remote_ip_location_lon]a
    required_fields = ~w[external_id name public_key]a
    
    %Gateway{}
    |> cast(attrs, upsert_fields)
    |> put_default_value(:name, fn ->
      Domain.Crypto.random_token(5, encoder: :user_friendly)
    end)
    |> Domain.Gateway.changeset()
    |> validate_required(required_fields)
    |> validate_base64(:public_key)
    |> validate_length(:public_key, is: 44)
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> put_change(:last_seen_user_agent, context.user_agent)
    |> put_change(:last_seen_remote_ip, context.remote_ip)
    |> put_change(:last_seen_remote_ip_location_region, context.remote_ip_location_region)
    |> put_change(:last_seen_remote_ip_location_city, context.remote_ip_location_city)
    |> put_change(:last_seen_remote_ip_location_lat, context.remote_ip_location_lat)
    |> put_change(:last_seen_remote_ip_location_lon, context.remote_ip_location_lon)
    |> put_gateway_version()
    |> put_change(:account_id, group.account_id)
    |> put_change(:group_id, group.id)
  end

  defp put_gateway_version(changeset) do
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

  defp finalize_upsert(%Gateway{} = gateway, ipv4, ipv6) do
    import Ecto.Changeset
    
    gateway
    |> change()
    |> put_change(:ipv4, ipv4)
    |> put_change(:ipv6, ipv6)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.{Repo, Network, Safe}
    alias Domain.Gateway

    def upsert_gateway(changeset, _group) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:gateway, changeset,
        conflict_target: upsert_conflict_target(),
        on_conflict: upsert_on_conflict(),
        returning: true
      )
      |> resolve_address_multi(:ipv4)
      |> resolve_address_multi(:ipv6)
      |> Ecto.Multi.update(:gateway_with_address, fn
        %{gateway: %Gateway{} = gateway, ipv4: ipv4, ipv6: ipv6} ->
          API.Gateway.Socket.finalize_upsert(gateway, ipv4, ipv6)
      end)
      |> Safe.transact()
      |> case do
        {:ok, %{gateway_with_address: gateway}} -> {:ok, gateway}
        {:error, :gateway, changeset, _effects_so_far} -> {:error, changeset}
      end
    end
    
    defp upsert_conflict_target do
      {:unsafe_fragment, ~s/(account_id, group_id, external_id)/}
    end
    
    defp upsert_on_conflict do
      conflict_replace_fields = ~w[name
                                  public_key
                                  last_seen_user_agent
                                  last_seen_remote_ip
                                  last_seen_remote_ip_location_region
                                  last_seen_remote_ip_location_city
                                  last_seen_remote_ip_location_lat
                                  last_seen_remote_ip_location_lon
                                  last_seen_version
                                  last_seen_at
                                  updated_at]a
      {:replace, conflict_replace_fields}
    end
    
    defp resolve_address_multi(multi, type) do
      Ecto.Multi.run(multi, type, fn _repo, %{gateway: %Gateway{} = gateway} ->
        if address = Map.get(gateway, type) do
          {:ok, address}
        else
          {:ok, Network.fetch_next_available_address!(gateway.account_id, type)}
        end
      end)
    end
  end
end
