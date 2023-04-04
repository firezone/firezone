defmodule Web.DebugController do
  @moduledoc """
  Dev only:

  /dev/session
  /dev/samly
  """
  use Web, :controller

  def samly(conn, _params) do
    resp = """
    Samly.Provider state:
    #{pretty(Application.get_env(:samly, Samly.Provider))}

    Service Providers:
    #{pretty(Application.get_env(:samly, :service_providers))}

    Identity Providers:
    #{pretty(Application.get_env(:samly, :identity_providers))}

    Samly Session:
    #{pretty(Samly.get_active_assertion(conn))}
    """

    send_resp(conn, :ok, resp)
  end

  def session(conn, _params) do
    send_resp(conn, :ok, pretty(get_session(conn)))
  end

  defp pretty(stuff) do
    inspect(stuff, pretty: true)
  end
end
