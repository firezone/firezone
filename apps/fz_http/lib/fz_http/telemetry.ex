defmodule FzHttp.Telemetry do
  @moduledoc """
  Functions for various telemetry events.
  """

  alias FzHttp.Users

  def add_device(device) do
    telemetry_module().capture(
      "add_device",
      distinct_id: fqdn(),
      device_uuid_hash: hash(device.uuid),
      user_email_hash: hash(user_email(device.user_id)),
      admin_email_hash: hash(admin_email())
    )
  end

  def add_user(user) do
    telemetry_module().capture(
      "add_user",
      distinct_id: fqdn(),
      user_email_hash: hash(user.email),
      admin_email_hash: hash(admin_email())
    )
  end

  def add_rule(rule) do
    telemetry_module().capture(
      "add_rule",
      distinct_id: fqdn(),
      rule_uuid_hash: hash(rule.uuid),
      admin_email_hash: hash(admin_email())
    )
  end

  def delete_device(device) do
    telemetry_module().capture(
      "delete_device",
      distinct_id: fqdn(),
      device_uuid_hash: hash(device.uuid),
      user_email_hash: hash(user_email(device.user_id)),
      admin_email_hash: hash(admin_email())
    )
  end

  def delete_user(user) do
    telemetry_module().capture(
      "delete_user",
      distinct_id: fqdn(),
      user_email_hash: hash(user.email),
      admin_email_hash: hash(admin_email())
    )
  end

  def delete_rule(rule) do
    telemetry_module().capture(
      "delete_rule",
      distinct_id: fqdn(),
      rule_uuid_hash: hash(rule.uuid),
      admin_email_hash: hash(admin_email())
    )
  end

  defp hash(str) do
    :crypto.hash(:sha256, str) |> Base.encode16()
  end

  defp telemetry_module do
    Application.fetch_env!(:fz_http, :telemetry_module)
  end

  def user_email(user_id) do
    Users.get_user!(user_id).email
  end

  defp admin_email do
    Application.fetch_env!(:fz_http, :admin_email)
  end

  defp fqdn do
    Application.fetch_env!(:fz_http, :url_host)
  end
end
