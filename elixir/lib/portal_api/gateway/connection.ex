defmodule PortalAPI.Gateway.Connection do
  @moduledoc """
  Connects a Gateway token, on `/gateway` or on `/device/v1`. Both sockets resolve the same
  device row for the same token and firezone_id, so a host that changes binary keeps its row,
  its site and its authorizations.
  """
  alias Portal.Authentication
  alias Portal.{Device, PG, Version}
  alias __MODULE__.Database
  require Logger
  require OpenTelemetry.Tracer
  import Ecto.Changeset
  import Portal.Changeset

  @reported_metadata_fields ~w[
    device_serial
    device_uuid
  ]a

  @doc """
  Verifies the token, then finds or creates its gateway. Returns what the socket assigns.
  """
  @spec connect(map(), map()) :: {:ok, map()} | {:error, term()}
  def connect(attrs, connect_info) do
    unless Application.get_env(:portal, :sql_sandbox) do
      Portal.Repo.put_dynamic_repo(Portal.Repo.Api)
    end

    :otel_propagator_text_map.extract(connect_info.trace_context_headers)

    OpenTelemetry.Tracer.with_span "gateway.connect" do
      with {:ok, encoded_token} <- PortalAPI.Sockets.extract_token(attrs, connect_info),
           :ok <- PortalAPI.Sockets.RateLimit.check(connect_info, token: encoded_token) do
        do_connect(encoded_token, attrs, connect_info)
      end
    end
  end

  defp do_connect(encoded_token, attrs, connect_info) do
    context = PortalAPI.Sockets.auth_context(connect_info, :gateway)
    attrs = normalize_device_attrs(attrs)

    with {:ok, gateway_token} <- Authentication.verify_gateway_token(encoded_token),
         {:ok, subject} <- Authentication.build_subject(gateway_token, context),
         {:ok, public_key} <- validate_public_key(attrs),
         {:ok, site, gateway} <- resolve_gateway(gateway_token, attrs, subject),
         :ok <- ensure_gateway_not_connected(gateway),
         {:ok, gateway} <- put_reported_metadata(gateway, attrs, subject),
         {:ok, gateway} <- maybe_put_firezone_id(gateway, site, attrs, subject) do
      version = derive_version(context.user_agent)
      {context, version} = PortalAPI.Sockets.truncate_session_fields(context, version)
      previous_public_key = gateway.public_key
      gateway = apply_session(gateway, gateway_token.id, public_key, context, version)

      OpenTelemetry.Tracer.set_attributes(%{
        token_id: gateway_token.id,
        gateway_id: gateway.id,
        account_id: gateway.account_id,
        version: version
      })

      {:ok,
       %{
         token_id: gateway_token.id,
         subject: subject,
         site: site,
         gateway: gateway,
         previous_public_key: previous_public_key,
         session_ref: make_ref(),
         opentelemetry_span_ctx: OpenTelemetry.Tracer.current_span_ctx(),
         opentelemetry_ctx: OpenTelemetry.Ctx.get_current()
       }}
    else
      {:error, {:rate_limit, retry_after_ms}} ->
        {:error, {:rate_limit, retry_after_ms}}

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

  # First-wins: a gateway that appears connected must disconnect before a
  # replacement is allowed. Cross-node registration races are resolved by the
  # channel's connection-claim protocol after join.
  defp ensure_gateway_not_connected(gateway) do
    case PG.members(gateway.id) do
      [] -> :ok
      _pids -> {:error, :conflict}
    end
  end

  # Multi-owner (site) token: gateways are identified by their reported
  # firezone_id and created on the fly
  defp resolve_gateway(%Portal.DeviceToken{device_id: nil} = gateway_token, attrs, subject) do
    with {:ok, site} <- Database.fetch_site(gateway_token.site_id, subject),
         changeset = insert_changeset(site, attrs),
         {:ok, _} <- apply_action(changeset, :validate),
         {:ok, gateway} <- Database.find_or_create_gateway(site, changeset, subject) do
      {:ok, site, gateway}
    end
  end

  # Single-owner token: the token identifies the gateway directly; the
  # reported firezone_id is kept in sync as a telemetry hint
  defp resolve_gateway(%Portal.DeviceToken{} = gateway_token, _attrs, subject) do
    with {:ok, gateway} <- Database.fetch_gateway(gateway_token.device_id, subject) do
      {:ok, gateway.site_device.site, gateway}
    end
  end

  # Hardware metadata is self-reported on every connection. Only fields present
  # in the socket params are cast, so an older gateway that omits a field keeps
  # the value already stored on its device row.
  defp put_reported_metadata(%Device{} = gateway, attrs, subject) do
    changeset =
      gateway
      |> cast(attrs, @reported_metadata_fields)
      |> Device.changeset()

    if changeset.changes == %{} do
      {:ok, gateway}
    else
      Database.update_gateway(changeset, subject)
    end
  end

  # Identity comes from the token, so the stored firezone_id is only a
  # telemetry hint: keep it in sync with whatever the gateway currently
  # reports (a rebuilt host generates a fresh one)
  defp maybe_put_firezone_id(
         %Device{firezone_id: reported} = gateway,
         _site,
         %{"firezone_id" => reported},
         _subject
       ) do
    {:ok, gateway}
  end

  defp maybe_put_firezone_id(%Device{} = gateway, site, %{"firezone_id" => reported}, subject)
       when is_binary(reported) and reported != "" do
    changeset =
      gateway
      |> cast(%{firezone_id: reported}, [:firezone_id])
      |> Device.changeset()

    case Database.update_firezone_id(site, changeset, subject) do
      {:ok, gateway} ->
        {:ok, gateway}

      {:error, reason} ->
        # The telemetry hint is best-effort; never block the connection on it
        Logger.info("Failed to persist reported gateway firezone_id", error: {:error, reason})

        {:ok, gateway}
    end
  end

  defp maybe_put_firezone_id(%Device{} = gateway, _site, _attrs, _subject), do: {:ok, gateway}

  defp insert_changeset(site, attrs) do
    insert_fields = [:firezone_id, :name | @reported_metadata_fields]
    required_fields = ~w[firezone_id name]a

    %Device{}
    |> cast(attrs, insert_fields)
    |> put_default_value(:name, fn ->
      Portal.Crypto.random_token(5, encoder: :user_friendly)
    end)
    |> put_change(:type, :gateway)
    |> put_embed(:upstream_dns, %Portal.UpstreamDNS{type: :system})
    |> put_change(:account_id, site.account_id)
    |> Portal.Devices.put_free_slug(site.account_id, nil)
    |> put_assoc(:site_device, Portal.Devices.site_device_changeset(site))
    |> validate_required(required_fields)
    |> Device.changeset()
    |> public_socket_changeset()
  end

  # The connection snapshot lives directly on the device struct: these are the
  # same fields the flush later persists as the device's latest session.
  defp apply_session(gateway, token_id, public_key, context, version) do
    %{
      gateway
      | token_id: token_id,
        public_key: public_key,
        last_seen_user_agent: context.user_agent,
        last_seen_remote_ip: context.remote_ip,
        last_seen_remote_ip_location_region: context.remote_ip_location_region,
        last_seen_remote_ip_location_city: context.remote_ip_location_city,
        last_seen_remote_ip_location_lat: context.remote_ip_location_lat,
        last_seen_remote_ip_location_lon: context.remote_ip_location_lon,
        last_seen_version: version,
        last_seen_device_v1: false,
        last_seen_at: DateTime.utc_now()
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
    alias Portal.SiteDevice

    # Connect hot path: the site rides along in the same query.
    def fetch_gateway(id, subject) do
      result =
        from(d in Device,
          where: d.id == ^id,
          where: d.type == :gateway,
          join: sd in SiteDevice,
          on: sd.account_id == d.account_id and sd.device_id == d.id,
          join: s in Site,
          on: s.account_id == sd.account_id and s.id == sd.site_id,
          preload: [site_device: {sd, site: s}]
        )
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        %Device{} = gateway -> {:ok, gateway}
        nil -> {:error, :not_found}
        {:error, :unauthorized} = error -> error
      end
    end

    def update_gateway(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    # Site-token connects find a gateway by its firezone_id, so a gateway only
    # takes one that no other gateway in its account holds.
    def update_firezone_id(site, changeset, subject) do
      firezone_id = Ecto.Changeset.get_field(changeset, :firezone_id)

      Safe.transact(fn ->
        lock_registration(site, firezone_id)

        case gateway_in_account?(site, firezone_id, subject) do
          false -> update_gateway(changeset, subject)
          true -> {:error, :firezone_id_taken}
          {:error, :unauthorized} = error -> error
        end
      end)
    end

    def fetch_site(id, subject) do
      result =
        from(s in Site, where: s.id == ^id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        %Site{} = site -> {:ok, site}
        nil -> {:error, :not_found}
        {:error, :unauthorized} = error -> error
      end
    end

    # The lookup runs again under a lock so two first connects of one gateway
    # cannot both insert it. A gateway that connects with another site's token
    # moves to that site while it is offline.
    def find_or_create_gateway(site, changeset, subject) do
      firezone_id = Ecto.Changeset.get_field(changeset, :firezone_id)

      case find_gateway(site, firezone_id, subject) do
        nil -> Safe.transact(fn -> find_or_insert_locked(site, firezone_id, changeset, subject) end)
        %Device{} = gateway -> {:ok, gateway}
        {:error, :unauthorized} = error -> error
      end
    end

    defp find_or_insert_locked(site, firezone_id, changeset, subject) do
      lock_registration(site, firezone_id)

      case find_gateway(site, firezone_id, subject) do
        nil -> move_or_insert_gateway(site, firezone_id, changeset, subject)
        %Device{} = gateway -> {:ok, gateway}
        {:error, :unauthorized} = error -> error
      end
    end

    defp move_or_insert_gateway(site, firezone_id, changeset, subject) do
      case find_gateway_in_other_site(site, firezone_id, subject) do
        nil -> insert_gateway(changeset, subject)
        %Device{} = gateway -> move_gateway(gateway, site, subject)
        {:error, :unauthorized} = error -> error
      end
    end

    defp find_gateway_in_other_site(site, firezone_id, subject) do
      from(d in Device,
        join: sd in SiteDevice,
        on: sd.account_id == d.account_id and sd.device_id == d.id,
        where: sd.site_id != ^site.id,
        where: d.firezone_id == ^firezone_id,
        where: d.type == :gateway,
        order_by: [desc_nulls_last: d.last_seen_at, asc: d.id],
        limit: 1
      )
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    # Authorizations toward the gateway were granted for the old site's
    # resources, so they go with the move.
    defp move_gateway(gateway, site, subject) do
      if Portal.PG.members(gateway.id) == [] do
        {_count, _} =
          from(sd in SiteDevice,
            where: sd.device_id == ^gateway.id,
            update: [set: [site_id: ^site.id]]
          )
          |> Safe.scoped(subject)
          |> Safe.update_all([])

        {_count, _} =
          from(pa in Portal.PolicyAuthorization, where: pa.receiving_device_id == ^gateway.id)
          |> Safe.scoped(subject)
          |> Safe.delete_all()

        {:ok, gateway}
      else
        {:error, :conflict}
      end
    end

    # Keep this lookup scoped to the token's site. Gateways flagged
    # `firezone_id_exempt` are mostly cloned VMs that share a firezone_id across
    # sites and each need their own row. Widening the lookup, or merging those
    # rows, gives both clones one row and the second one is refused.
    defp find_gateway(site, firezone_id, subject) do
      from(d in Device,
        join: sd in SiteDevice,
        on: sd.account_id == d.account_id and sd.device_id == d.id,
        where: sd.site_id == ^site.id,
        where: d.firezone_id == ^firezone_id,
        where: d.type == :gateway,
        order_by: [asc: d.inserted_at, asc: d.id],
        limit: 1
      )
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    defp gateway_in_account?(site, firezone_id, subject) do
      from(d in Device,
        where: d.account_id == ^site.account_id,
        where: d.firezone_id == ^firezone_id,
        where: d.type == :gateway
      )
      |> Safe.scoped(subject)
      |> Safe.exists?()
    end

    @dialyzer {:no_opaque, [insert_gateway: 2]}
    defp insert_gateway(changeset, subject) do
      with :ok <- Portal.Devices.RegistrationRateLimit.check(subject.account) do
        changeset |> Safe.scoped(subject) |> Safe.insert()
      end
    end

    defp lock_registration(site, firezone_id) do
      <<key::signed-64, _::binary>> =
        :crypto.hash(:sha256, "gateway_registration:" <> site.account_id <> ":" <> firezone_id)

      {:ok, _} = Safe.unscoped() |> Safe.query("SELECT pg_advisory_xact_lock($1)", [key])
    end
  end
end
