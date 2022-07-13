defmodule FzHttp.Telemetry do
  @moduledoc """
  Functions for various telemetry events.
  """

  require Logger

  alias FzHttp.Devices
  alias FzHttp.MFA
  alias FzHttp.Users

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
    telemetry_module().capture(
      "ping",
      common_fields() ++
        [
          user_count: Users.count(),
          device_count: Devices.count(),
          max_devices_for_users: Devices.max_count_by_user_id(),
          users_with_mfa: MFA.count_distinct_by_user_id(),
          users_with_mfa_totp: MFA.count_distinct_totp_by_user_id(),
          openid_providers: length(conf(:openid_connect_providers)),
          auto_create_oidc_users: conf(:auto_create_oidc_users),
          unprivileged_device_management: conf(:allow_unprivileged_device_management),
          local_authentication: conf(:local_auth_enabled),
          disable_vpn_on_oidc_error: conf(:disable_vpn_on_oidc_error),
          outbound_email: outbound_email?(),
          external_database: external_database?()
        ]
    )
  end

  defp common_fields do
    [
      distinct_id: distinct_id(),
      fqdn: fqdn(),
      version: version(),
      kernel_version: "#{os_type()} #{os_version()}"
    ]
  end

  defp telemetry_module do
    Application.fetch_env!(:fz_http, :telemetry_module)
  end

  defp fqdn do
    :fz_http
    |> Application.fetch_env!(FzHttpWeb.Endpoint)
    |> Keyword.get(:url)
    |> Keyword.get(:host)
  end

  defp distinct_id do
    Application.fetch_env!(:fz_http, :telemetry_id)
  end

  defp version do
    Application.spec(:fz_http, :vsn) |> to_string()
  end

  defp external_database? do
    db_host = Application.fetch_env!(:fz_http, FzHttp.Repo)[:hostname]

    db_host != "localhost" && db_host != "127.0.0.1"
  end

  defp outbound_email? do
    from_email = Application.fetch_env!(:fz_http, FzHttp.Mailer)[:from_email]

    !is_nil(from_email)
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

  defp conf(key) do
    Application.fetch_env!(:fz_http, key)
  end
end
