defmodule FzHttpWeb.MockEvents do
  @moduledoc """
  A Mock module for testing external events

  XXX: This is used because FzHttp tests will launch multiple FzVpn servers.
  Instead, we should find a way to maintain a persistent link to one FzVpn server
  inside FzHttp and use that for the tests.
  """

  def delete_device(_device), do: maybe_mock_error()
  def update_device(_device), do: maybe_mock_error()
  def add_rule(_rule), do: maybe_mock_error()
  def delete_rule(_rule), do: maybe_mock_error()
  def set_config, do: maybe_mock_error()
  def set_rules, do: maybe_mock_error()

  defp maybe_mock_error do
    if Application.get_env(:fz_http, :mock_events_module_errors) do
      {:error, "mocked error"}
    else
      :ok
    end
  end
end
