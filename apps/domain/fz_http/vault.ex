defmodule FzHttp.Vault do
  @moduledoc """
  Manages encrypted DB fields.
  """

  use Cloak.Vault, otp_app: :fz_http
end
