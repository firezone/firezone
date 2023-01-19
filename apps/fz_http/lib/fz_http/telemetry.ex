defmodule FzHttp.Telemetry do
  @moduledoc """
  Functions for various telemetry events.
  """

  require Logger

  alias FzHttp.{Devices, MFA, Users}

  def create_api_token do
    telemetry_module().capture(
      "add_api_token",
      common_fields()
    )
  end

  def delete_api_token(api_token) do
    telemetry_module().capture(
      "delete_api_token",
      common_fields() ++
        [
          api_token_created_at: api_token.inserted_at
        ]
    )
  end

  def add_device do
    telemetry_module().capture(
      "add_device",
      common_fields()
    )
  end

  def add_user do
    telemetry_module().capture(
      "add_user",
      common_fields()
    )
  end

  def add_rule do
    telemetry_module().capture(
      "add_rule",
      common_fields()
    )
  end

  def delete_device do
    telemetry_module().capture(
      "delete_device",
      common_fields()
    )
  end

  def delete_user do
    telemetry_module().capture(
      "delete_user",
      common_fields()
    )
  end

  def delete_rule do
    telemetry_module().capture(
      "delete_rule",
      common_fields()
    )
  end

  def login do
    telemetry_module().capture(
      "login",
      common_fields()
    )
  end

  def disable_user do
    telemetry_module().capture(
      "disable_user",
      common_fields()
    )
  end

  def fz_http_started do
    telemetry_module().capture(
      "fz_http_started",
      common_fields()
    )
  end

  def ping do
    telemetry_module().capture("ping", ping_data())
  end

  # How far back to count handshakes as an active device
  @active_device_window 86_400
  def ping_data do
    common_fields() ++
      [
        devices_active_within_24h: Devices.count_active_within(@active_device_window),
        admin_count: Users.count_by_role(:admin),
        user_count: Users.count(),
        in_docker: in_docker?(),
        device_count: Devices.count(),
        max_devices_for_users: Devices.max_count_by_user_id(),
        users_with_mfa: MFA.count_distinct_by_user_id(),
        users_with_mfa_totp: MFA.count_distinct_totp_by_user_id(),
        openid_providers: length(FzHttp.Configurations.get!(:openid_connect_providers)),
        saml_providers: length(FzHttp.Configurations.get!(:saml_identity_providers)),
        unprivileged_device_management:
          FzHttp.Configurations.get!(:allow_unprivileged_device_management),
        unprivileged_device_configuration:
          FzHttp.Configurations.get!(:allow_unprivileged_device_configuration),
        local_authentication: FzHttp.Configurations.get!(:local_auth_enabled),
        disable_vpn_on_oidc_error: FzHttp.Configurations.get!(:disable_vpn_on_oidc_error),
        outbound_email: outbound_email?(),
        external_database:
          external_database?(Map.new(FzHttp.Config.fetch_env!(:fz_http, FzHttp.Repo))),
        logo_type: FzHttp.Configurations.logo_type(FzHttp.Configurations.get!(:logo))
      ]
  end

  defp in_docker? do
    File.exists?("/.dockerenv")
  end

  defp common_fields do
    [
      distinct_id: FzHttp.Config.fetch_env!(:fz_http, :telemetry_id),
      fqdn: fqdn(),
      version: version(),
      kernel_version: "#{os_type()} #{os_version()}"
    ]
  end

  defp telemetry_module do
    FzHttp.Config.fetch_env!(:fz_http, :telemetry_module)
  end

  defp fqdn do
    :fz_http
    |> FzHttp.Config.fetch_env!(FzHttpWeb.Endpoint)
    |> Keyword.get(:url)
    |> Keyword.get(:host)
  end

  defp version do
    Application.spec(:fz_http, :vsn) |> to_string()
  end

  defp external_database?(repo_conf) when is_map_key(repo_conf, :hostname) do
    is_external_db?(repo_conf.hostname)
  end

  defp external_database?(repo_conf) when is_map_key(repo_conf, :url) do
    %{host: host} = URI.parse(repo_conf.url)

    is_external_db?(host)
  end

  defp is_external_db?(host) do
    host != "localhost" && host != "127.0.0.1"
  end

  defp outbound_email? do
    not is_nil(FzHttp.Config.fetch_env!(:fz_http, FzHttpWeb.Mailer)[:from_email])
  end

  defp os_type do
    case :os.type() do
      {:unix, type} ->
        "#{type}"

      _ ->
        "other"
    end
  end

  defp os_version do
    case :os.version() do
      {major, minor, patch} ->
        "#{major}.#{minor}.#{patch}"

      _ ->
        "0.0.0"
    end
  end
end
