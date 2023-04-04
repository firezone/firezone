defmodule Domain.Vault do
  @moduledoc """
  Manages encrypted DB fields.
  """
  use Cloak.Vault, otp_app: :domain
end
