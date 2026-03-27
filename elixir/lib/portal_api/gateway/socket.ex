defmodule PortalAPI.Gateway.Socket do
  use Phoenix.Socket
  alias Portal.Authentication
  alias Portal.{Device, GatewaySession, Version}
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
    unless Application.get_env(:portal, :sql_sandbox) do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Api)
      Portal.Repo.Replica.put_dynamic_repo(Portal.Repo.Replica.Api)
    end

    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "gateway.connect" do
      with {:ok, encoded_token} <- PortalAPI.Sockets.extract_token(attrs, connect_info),
           :ok <- PortalAPI.Sockets.RateLimit.check(connect_info, token: encoded_token) do
        do_connect(encoded_token, attrs, socket, connect_info)
      end
    end
  end

  @impl true
  def id(socket), do: Portal.Sockets.socket_id(socket.assigns.token_id)

  defp do_connect(encoded_token, attrs, socket, connect_info) do
    context = PortalAPI.Sockets.auth_context(connect_info, :gateway)
    attrs = normalize_device_attrs(attrs)

    with {:ok, gateway_token} <- Authentication.verify_gateway_token(encoded_token),
         {:ok, public_key} <- validate_public_key(attrs),
         {:ok, site} <- Database.fetch_site(gateway_token.account_id, gateway_token.site_id),
         changeset = insert_changeset(site, attrs),
         {:ok, _} <- apply_action(changeset, :validate),
         {:ok, gateway} <- Database.find_or_create_gateway(changeset) do
      version = derive_version(context.user_agent)
      {context, version} = PortalAPI.Sockets.truncate_session_fields(context, version)
      session = build_session(gateway, gateway_token.id, public_key, context, version)
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
      {:error, %Ecto.Changeset{} = changeset} ->
        changeset = public_socket_changeset(changeset)
        trace = Process.info(self(), :current_stacktrace)

        Logger.info("Gateway socket connection failed",
          error: {:error, changeset},
          stacktrace: trace
        )

        {:error, changeset}

      error ->
        trace = Process.info(self(), :current_stacktrace)
        Logger.info("Gateway socket connection failed", error: error, stacktrace: trace)

        error
    end
  end

  defp insert_changeset(site, attrs) do
    insert_fields = ~w[firezone_id name]a
    required_fields = ~w[firezone_id name]a

    %Device{}
    |> cast(attrs, insert_fields)
    |> put_default_value(:name, fn ->
      Portal.Crypto.random_token(5, encoder: :user_friendly)
    end)
    |> put_change(:type, :gateway)
    |> put_change(:account_id, site.account_id)
    |> put_change(:site_id, site.id)
    |> validate_required(required_fields)
    |> Device.changeset()
    |> public_socket_changeset()
  end

  defp build_session(gateway, token_id, public_key, context, version) do
    %GatewaySession{
      device_id: gateway.id,
      account_id: gateway.account_id,
      gateway_token_id: token_id,
      public_key: public_key,
      user_agent: context.user_agent,
      remote_ip: context.remote_ip,
      remote_ip_location_region: context.remote_ip_location_region,
      remote_ip_location_city: context.remote_ip_location_city,
      remote_ip_location_lat: context.remote_ip_location_lat,
      remote_ip_location_lon: context.remote_ip_location_lon,
      version: version
    }
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

  defmodule Database do
    import Ecto.Query
    alias Portal.Device

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

    @dialyzer {:no_opaque, [find_or_create_gateway: 1]}
    def find_or_create_gateway(changeset) do
      account_id = Ecto.Changeset.get_field(changeset, :account_id)
      site_id = Ecto.Changeset.get_field(changeset, :site_id)
      firezone_id = Ecto.Changeset.get_field(changeset, :firezone_id)

      existing =
        if firezone_id do
          from(d in Device,
            where: d.account_id == ^account_id,
            where: d.site_id == ^site_id,
            where: d.firezone_id == ^firezone_id,
            where: d.type == :gateway
          )
          |> Safe.unscoped(:replica)
          |> Safe.one(fallback_to_primary: true)
        end

      if existing do
        {:ok, existing}
      else
        changeset
        |> Safe.unscoped()
        |> Safe.insert()
      end
    end
  end
end
