defmodule FgHttp.Vault do
  @moduledoc """
  Manages encrypted DB fields.
  """

  use Cloak.Vault, otp_app: :fg_http
end
