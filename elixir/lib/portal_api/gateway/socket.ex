defmodule PortalAPI.Gateway.Socket do
  use Phoenix.Socket
  alias Portal.Authentication
  alias Portal.{Gateway, GatewaySession, Version}
  alias __MODULE__.Database
  require Logger
  require OpenTelemetry.Tracer
  import Ecto.Changeset
  import Portal.Changeset

  ## Channels

  channel "gateway", PortalAPI.Gateway.Channel

  ## Authentication

  @impl true
  def connect(attrs, socket, connect_info) do
    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "gateway.connect" do
      with :ok <- PortalAPI.Sockets.RateLimit.check(connect_info),
           {:ok, encoded_token} <- PortalAPI.Sockets.extract_token(attrs, connect_info) do
        do_connect(encoded_token, attrs, socket, connect_info)
      end
    end
  end

  @impl true
  def id(socket), do: Portal.Sockets.socket_id(socket.assigns.token_id)

  defp do_connect(encoded_token, attrs, socket, connect_info) do
    context = PortalAPI.Sockets.auth_context(connect_info, :gateway)
    attrs = Map.take(attrs, ~w[external_id name public_key])

    with {:ok, gateway_token} <- Authentication.verify_gateway_token(encoded_token),
         {:ok, site} <- Database.fetch_site(gateway_token.account_id, gateway_token.site_id),
         changeset = upsert_changeset(site, attrs),
         {:ok, gateway} <- Database.upsert_gateway(changeset, site) do
      version = derive_version(context.user_agent)
      session = build_session(gateway, gateway_token.id, context, version)
      GatewaySession.Buffer.insert(session)

      OpenTelemetry.Tracer.set_attributes(%{
        token_id: gateway_token.id,
        gateway_id: gateway.id,
        account_id: gateway.account_id,
        version: version
      })

      socket =
        socket
        |> assign(:token_id, gateway_token.id)
        |> assign(:site, site)
        |> assign(:gateway, gateway)
        |> assign(:session, session)
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

  defp upsert_changeset(site, attrs) do
    upsert_fields = ~w[external_id name public_key]a
    required_fields = ~w[external_id name public_key]a

    %Gateway{}
    |> cast(attrs, upsert_fields)
    |> put_default_value(:name, fn ->
      Portal.Crypto.random_token(5, encoder: :user_friendly)
    end)
    |> Portal.Gateway.changeset()
    |> validate_required(required_fields)
    |> validate_base64(:public_key)
    |> validate_length(:public_key, is: 44)
    |> put_change(:account_id, site.account_id)
    |> put_change(:site_id, site.id)
  end

  defp build_session(gateway, token_id, context, version) do
    %GatewaySession{
      gateway_id: gateway.id,
      account_id: gateway.account_id,
      gateway_token_id: token_id,
      user_agent: context.user_agent,
      remote_ip: context.remote_ip,
      remote_ip_location_region: context.remote_ip_location_region,
      remote_ip_location_city: context.remote_ip_location_city,
      remote_ip_location_lat: context.remote_ip_location_lat,
      remote_ip_location_lon: context.remote_ip_location_lon,
      version: version
    }
  end

  defp derive_version(user_agent) do
    case Version.fetch_version(user_agent) do
      {:ok, version} -> version
      _ -> nil
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Gateway
    alias Portal.IPv4Address
    alias Portal.IPv6Address

    alias Portal.Safe
    alias Portal.Site

    def fetch_site(account_id, id) do
      result =
        from(s in Site,
          where: s.account_id == ^account_id,
          where: s.id == ^id
        )
        |> Safe.unscoped(:replica)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        site -> {:ok, site}
      end
    end

    # OTP 28 dialyzer is stricter about opaque types (MapSet) inside Ecto.Multi
    @dialyzer {:no_opaque, upsert_gateway: 2}
    def upsert_gateway(changeset, _site) do
      account_id = Ecto.Changeset.get_field(changeset, :account_id)
      site_id = Ecto.Changeset.get_field(changeset, :site_id)
      external_id = Ecto.Changeset.get_field(changeset, :external_id)

      Ecto.Multi.new()
      |> Ecto.Multi.run(:existing_gateway, fn _repo, _changes ->
        existing =
          if external_id do
            from(g in Gateway,
              where: g.account_id == ^account_id,
              where: g.site_id == ^site_id,
              where: g.external_id == ^external_id,
              preload: [:ipv4_address, :ipv6_address]
            )
            |> Safe.unscoped(:replica)
            |> Safe.one(fallback_to_primary: true)
          end

        {:ok, existing}
      end)
      |> Ecto.Multi.insert(
        :gateway,
        changeset,
        conflict_target: upsert_conflict_target(),
        on_conflict: upsert_on_conflict(),
        returning: true
      )
      |> Ecto.Multi.run(:ipv4_address, fn _repo,
                                          %{existing_gateway: existing, gateway: gateway} ->
        if existing do
          {:ok, existing.ipv4_address}
        else
          IPv4Address.allocate_next_available_address(account_id, gateway_id: gateway.id)
        end
      end)
      |> Ecto.Multi.run(:ipv6_address, fn _repo,
                                          %{existing_gateway: existing, gateway: gateway} ->
        if existing do
          {:ok, existing.ipv6_address}
        else
          IPv6Address.allocate_next_available_address(account_id, gateway_id: gateway.id)
        end
      end)
      |> Safe.transact()
      |> case do
        {:ok, %{gateway: gateway, ipv4_address: ipv4_address, ipv6_address: ipv6_address}} ->
          {:ok, %{gateway | ipv4_address: ipv4_address, ipv6_address: ipv6_address}}

        {:error, :gateway, changeset, _effects_so_far} ->
          {:error, changeset}
      end
    end

    defp upsert_conflict_target do
      {:unsafe_fragment, ~s/(account_id, site_id, external_id)/}
    end

    defp upsert_on_conflict do
      conflict_replace_fields = ~w[name
                                  public_key
                                  updated_at]a
      {:replace, conflict_replace_fields}
    end
  end
end
