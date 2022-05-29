defmodule FzHttp.Telemetry do
  @moduledoc """
  Functions for various telemetry events.
  """

  alias FzCommon.CLI
  alias FzHttp.Users

  require Logger

  def add_device(device) do
    telemetry_module().capture(
      "add_device",
      common_fields() ++
        [
          device_uuid_hash: hash(device.uuid),
          user_email_hash: hash(user_email(device.user_id)),
          admin_email_hash: hash(admin_email())
        ]
    )
  end

  def add_user(user) do
    telemetry_module().capture(
      "add_user",
      common_fields() ++
        [
          user_email_hash: hash(user.email),
          admin_email_hash: hash(admin_email())
        ]
    )
  end

  def add_rule(rule) do
    telemetry_module().capture(
      "add_rule",
      common_fields() ++
        [
          rule_uuid_hash: hash(rule.uuid),
          admin_email_hash: hash(admin_email())
        ]
    )
  end

  def delete_device(device) do
    telemetry_module().capture(
      "delete_device",
      common_fields() ++
        [
          device_uuid_hash: hash(device.uuid),
          user_email_hash: hash(user_email(device.user_id)),
          admin_email_hash: hash(admin_email())
        ]
    )
  end

  def delete_user(user) do
    telemetry_module().capture(
      "delete_user",
      common_fields() ++
        [
          user_email_hash: hash(user.email),
          admin_email_hash: hash(admin_email())
        ]
    )
  end

  def delete_rule(rule) do
    telemetry_module().capture(
      "delete_rule",
      common_fields() ++
        [
          rule_uuid_hash: hash(rule.uuid),
          admin_email_hash: hash(admin_email())
        ]
    )
  end

  def login(user) do
    telemetry_module().capture(
      "login",
      common_fields() ++
        [
          user_email_hash: hash(user.email)
        ]
    )
  end

  def disable_user(user, reason) do
    telemetry_module().capture(
      "disable_user",
      common_fields() ++
        [user_email_hash: hash(user.email), reason: reason]
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
      common_fields()
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

  defp hash(str) do
    :crypto.hash(:sha256, str) |> Base.encode16()
  end

  defp telemetry_module do
    Application.fetch_env!(:fz_http, :telemetry_module)
  end

  defp user_email(user_id) do
    Users.get_user!(user_id).email
  end

  defp admin_email do
    Application.fetch_env!(:fz_http, :admin_email)
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
