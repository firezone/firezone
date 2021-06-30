defmodule CfCommon.ConfigFile do
  @moduledoc """
  Common config file operations.
  """
  alias CfCommon.CLI

  @static_config %{
    https_listen_port: "8800",
    https_listen_address: "127.0.0.1",
    wg_listen_port: "51820",
    database_url: "ecto://postgres:postgres@127.0.0.1/cloudfire"
  }

  # Write then load, ensures clean slate
  def init! do
    mkdir!()

    Map.merge(default_config(), generate_config!())
    |> write!()

    load!()
  end

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

  defp generate_config! do
    %{
      live_view_signing_salt: live_view_signing_salt!(),
      secret_key_base: secret_key_base!(),
      database_url: database_url!(),
      db_encryption_key: db_encryption_key!(),
      url_host: url_host!(),
      wg_server_key: wg_server_key!()
    }
  end

  defp mkdir! do
    CLI.exec!("mkdir -p $HOME/.cloudfire")
  end

  defp live_view_signing_salt! do
    CLI.exec!("openssl rand -base64 24")
  end

  defp secret_key_base! do
    CLI.exec!("openssl rand -base64 48")
  end

  defp db_encryption_key! do
    CLI.exec!("openssl rand -base64 32")
  end

  defp url_host! do
    CLI.exec!("hostname")
  end

  defp database_url! do
    "ecto://postgres:postgres@127.0.0.1/cloudfire"
  end

  defp wg_server_key! do
    CLI.exec!("wg genkey")
  end

  defp file_module do
    Application.get_env(:cf_common, :config_file_module)
  end

  defp base_path do
    System.fetch_env!("HOME") <> "/.cloudfire"
  end

  defp config_path do
    base_path() <> "/config.json"
  end

  defp default_config do
    Map.merge(
      @static_config,
      %{
        ssl_cert_file: base_path() <> "ssl/cert.pem",
        ssl_key_file: base_path() <> "ssl/key.pem"
      }
    )
  end
end
