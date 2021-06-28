defmodule CfHttp.Vault do
  @moduledoc """
  Manages encrypted DB fields.
  """

  use Cloak.Vault, otp_app: :cf_http
end
