defmodule CfCommon.FakeFile do
  @moduledoc """
  Provides mocked file operations for testing ConfigFile
  """

  @json ~s({
    "database_url": "ecto://postgres:postgres@127.0.0.1/cloudfire",
    "secret_key_base": "fMjyDw9RpP5+f8klEmeEWnBQKd2H7uKH/PQpOTug6vybretclzaE1k4Y3O2Bw8lX",
    "live_view_signing_salt": "EHcSipS+bFTFYMbFmvVR8lAuwYyfqcTE",
    "db_encryption_key": "8Wgh3dPubt6q4Y1PlYRuG9v50zQE+QTUzh8mJnkw+jc=",
    "ssl_cert_file": "$HOME/.cloudfire/ssl/cert.pem",
    "ssl_key_file": "$HOME/.cloudfire/ssl/key.pem",
    "url_host": "localhost",
    "wg_server_key": "KDp9lQ6OAi/VrfgYo5VIAqCJFs1Gs55GZRDoA7W8500=",
    "https_listen_port": "8800",
    "https_listen_address": "127.0.0.1",
    "wg_listen_port": "51820"
  })

  def read!(_), do: @json
  def write!(_, _, [:write]), do: :ok
  def exists?(_), do: true
end
