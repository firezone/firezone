defmodule Web.Plug.SamlyTargetUrl do
  @moduledoc """
  Plug to set target url for samly to later on redirect to after auth success
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opt) do
    put_session(conn, "target_url", "/auth/saml/callback")
  end
end
