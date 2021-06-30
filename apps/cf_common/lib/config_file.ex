defmodule CfCommon.ConfigFile do
  @moduledoc """
  Common config file operations.
  """

  def load! do
    %{} = Jason.decode!(file_module().read!(config_path()))
  end

  def write!(config) do
    config_path()
    |> file_module().write!(Jason.encode!(config), [:write])
  end

  def exists? do
    file_module().exists?(config_path())
  end

  defp config_path do
    System.fetch_env!("HOME") <> "/.cloudfire/config.json"
  end

  defp file_module do
    Application.fetch_env!(:cf_common, :config_file_module)
  end
end
