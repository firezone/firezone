defmodule Portal.Workers.DeleteExpiredOAuthClients do
  @moduledoc """
  Oban worker that evicts cached OAuth client metadata nobody depends on.

  The authorization endpoint is public, so anyone who controls one HTTPS host
  can make the portal cache a document for every path on it. A client is kept
  for as long as a grant or a pending code points at it; the rest go once their
  document has been stale for a while.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_expired_oauth_clients()

    Logger.info("Deleted #{count} expired OAuth clients")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.OAuthAuthorizationCode
    alias Portal.OAuthClient
    alias Portal.OAuthGrant
    alias Portal.Safe

    # A mounted consent screen keeps the client it was given; its session is
    # far shorter than this.
    @grace_seconds 60 * 60

    def delete_expired_oauth_clients do
      cutoff = DateTime.add(DateTime.utc_now(), -@grace_seconds, :second)

      from(c in OAuthClient, as: :clients)
      |> where([clients: c], c.metadata_expires_at <= ^cutoff)
      |> where(
        [clients: c],
        not exists(
          from(g in OAuthGrant, where: g.oauth_client_id == parent_as(:clients).id, select: 1)
        )
      )
      |> where(
        [clients: c],
        not exists(
          from(code in OAuthAuthorizationCode,
            where: code.oauth_client_id == parent_as(:clients).id,
            select: 1
          )
        )
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
