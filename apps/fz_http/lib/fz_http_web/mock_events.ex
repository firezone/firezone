defmodule FzHttpWeb.MockEvents do
  @moduledoc """
  A Mock module for testing external events

  XXX: This is used because FzHttp tests will launch multiple FzVpn servers.
  Instead, we should find a way to maintain a persistent link to one FzVpn server
  inside FzHttp and use that for the tests.
  """

  def delete_device(_device) do
    maybe_mock_error()
  end

  def create_user(_user) do
    :ok
  end

  def delete_user(_user) do
    :ok
  end

  def update_device(_device) do
    :ok
  end

  def add_rule(_rule) do
    :ok
  end

  def delete_rule(_rule) do
    :ok
  end

  def set_config do
    :ok
  end

  defp maybe_mock_error do
    if Application.get_env(:fz_http, :mock_events_module_errors) do
      {:error, "mocked error"}
    else
      :ok
    end
  end
end
