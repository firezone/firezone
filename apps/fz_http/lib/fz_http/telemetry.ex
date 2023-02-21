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
    %{
      openid_connect_providers: {_, openid_connect_providers},
      saml_identity_providers: {_, saml_identity_providers},
      allow_unprivileged_device_management: allow_unprivileged_device_management,
      allow_unprivileged_device_configuration: {_, allow_unprivileged_device_configuration},
      local_auth_enabled: {_, local_auth_enabled},
      disable_vpn_on_oidc_error: {_, disable_vpn_on_oidc_error},
      logo: {_, logo}
    } =
      FzHttp.Config.fetch_source_and_configs!([
        :openid_connect_providers,
        :saml_identity_providers,
        :allow_unprivileged_device_management,
        :allow_unprivileged_device_configuration,
        :local_auth_enabled,
        :disable_vpn_on_oidc_error,
        :logo
      ])

    common_fields() ++
      [
        devices_active_within_24h: Devices.count_active_within(@active_device_window),
        admin_count: Users.count_by_role(:admin),
        user_count: Users.count(),
        in_docker: in_docker?(),
        device_count: Devices.count(),
        max_devices_for_users: Devices.max_count_by_user_id(),
        users_with_mfa: MFA.count_users_with_method(),
        users_with_mfa_totp: MFA.count_users_with_totp_method(),
        openid_providers: length(openid_connect_providers),
        saml_providers: length(saml_identity_providers),
        unprivileged_device_management: allow_unprivileged_device_management,
        unprivileged_device_configuration: allow_unprivileged_device_configuration,
        local_authentication: local_auth_enabled,
        disable_vpn_on_oidc_error: disable_vpn_on_oidc_error,
        outbound_email: FzHttpWeb.Mailer.active?(),
        external_database:
          external_database?(Map.new(FzHttp.Config.fetch_env!(:fz_http, FzHttp.Repo))),
        logo_type: FzHttp.Config.Logo.type(logo)
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
