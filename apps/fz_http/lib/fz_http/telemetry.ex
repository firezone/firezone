defmodule FzHttp.Telemetry do
  @moduledoc """
  Functions for various telemetry events.
  """

  require Logger

  def add_network, do: capture("add_network")
  def delete_network, do: capture("delete_network")
  def add_device, do: capture("add_device")
  def add_user, do: capture("add_user")
  def add_rule, do: capture("add_rule")
  def delete_device, do: capture("delete_device")
  def delete_user, do: capture("delete_user")
  def delete_rule, do: capture("delete_rule")
  def login, do: capture("login")
  def disable_user, do: capture("disable_user")
  def fz_http_started, do: capture("fz_http_started")
  def ping, do: capture("ping")

  defp capture(name, extra_fields \\ []) do
    telemetry_module().capture(
      name,
      common_fields() ++ extra_fields
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
