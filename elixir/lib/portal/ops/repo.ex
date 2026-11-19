defmodule Portal.Ops.Repo do
  @moduledoc """
  The ops database. It keeps the state of the private ops dashboard, such as its
  admins and their passkeys, apart from customer data. It is a separate database on
  the same server, and it runs only where the dashboard is compiled in.
  """
  use Ecto.Repo,
    otp_app: :portal,
    adapter: Ecto.Adapters.Postgres

  @doc "True when the private ops dashboard (firezone/portal-ops) is compiled in."
  def enabled?, do: Code.ensure_loaded?(PortalOps.Endpoint)
end
