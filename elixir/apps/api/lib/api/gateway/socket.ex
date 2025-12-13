defmodule API.Gateway.Socket do
  use Phoenix.Socket
  alias Domain.Auth
  alias Domain.{Gateway, Version}
  alias __MODULE__.DB
  require Logger
  require OpenTelemetry.Tracer
  import Ecto.Changeset
  import Domain.Changeset

  ## Channels

  channel "gateway", API.Gateway.Channel

  ## Authentication

  @impl true
  def connect(%{"token" => encoded_token} = attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "gateway.connect" do
      context = API.Sockets.auth_context(connect_info, :gateway)
      attrs = Map.take(attrs, ~w[external_id name public_key])

      with {:ok, gateway_token} <- Auth.verify_gateway_token(encoded_token),
           {:ok, site} <- DB.fetch_site(gateway_token.site_id),
           changeset = upsert_changeset(site, attrs, context),
           {:ok, gateway} <- DB.upsert_gateway(changeset, site) do
        OpenTelemetry.Tracer.set_attributes(%{
          token_id: gateway_token.id,
          gateway_id: gateway.id,
          account_id: gateway.account_id,
          version: gateway.last_seen_version
        })

        socket =
          socket
          |> assign(:token_id, gateway_token.id)
          |> assign(:site, site)
          |> assign(:gateway, gateway)
          |> assign(:opentelemetry_span_ctx, OpenTelemetry.Tracer.current_span_ctx())
          |> assign(:opentelemetry_ctx, OpenTelemetry.Ctx.get_current())

        {:ok, socket}
      else
        error ->
          trace = Process.info(self(), :current_stacktrace)
          Logger.info("Gateway socket connection failed", error: error, stacktrace: trace)

          error
      end
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, :missing_token}
  end

  @impl true
  def id(socket), do: Domain.Sockets.socket_id(socket.assigns.token_id)

  defp upsert_changeset(site, attrs, context) do
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
    |> put_change(:account_id, site.account_id)
    |> put_change(:site_id, site.id)
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

  defmodule DB do
    import Ecto.Query
    alias Domain.{Network, Safe}
    alias Domain.Gateway
    alias Domain.Site

    def fetch_site(id) do
      result =
        from(s in Site, where: s.id == ^id)
        |> Safe.unscoped()
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        site -> {:ok, site}
      end
    end

    def upsert_gateway(changeset, _site) do
      account_id = Ecto.Changeset.get_field(changeset, :account_id)
      site_id = Ecto.Changeset.get_field(changeset, :site_id)
      external_id = Ecto.Changeset.get_field(changeset, :external_id)

      Ecto.Multi.new()
      |> Ecto.Multi.run(:existing, fn _repo, _changes ->
        existing =
          if external_id do
            from(g in Gateway,
              where: g.account_id == ^account_id,
              where: g.site_id == ^site_id,
              where: g.external_id == ^external_id,
              select: %{ipv4: g.ipv4, ipv6: g.ipv6}
            )
            |> Safe.unscoped()
            |> Safe.one()
          end

        {:ok, existing}
      end)
      |> resolve_address_multi(:ipv4, account_id)
      |> resolve_address_multi(:ipv6, account_id)
      |> Ecto.Multi.insert(
        :gateway,
        fn %{ipv4: ipv4, ipv6: ipv6} ->
          changeset
          |> Ecto.Changeset.put_change(:ipv4, ipv4)
          |> Ecto.Changeset.put_change(:ipv6, ipv6)
        end,
        conflict_target: upsert_conflict_target(),
        on_conflict: upsert_on_conflict(),
        returning: true
      )
      |> Safe.transact()
      |> case do
        {:ok, %{gateway: gateway}} -> {:ok, gateway}
        {:error, :gateway, changeset, _effects_so_far} -> {:error, changeset}
      end
    end

    defp upsert_conflict_target do
      {:unsafe_fragment, ~s/(account_id, site_id, external_id)/}
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

    defp resolve_address_multi(multi, type, account_id) do
      Ecto.Multi.run(multi, type, fn _repo, %{existing: existing} ->
        if existing && Map.get(existing, type) do
          {:ok, Map.get(existing, type)}
        else
          {:ok, Network.fetch_next_available_address!(account_id, type)}
        end
      end)
    end
  end
end
