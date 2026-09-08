defmodule Portal.Workers.DeleteExpiredOAuthAuthorizationCodes do
  @moduledoc """
  Oban worker that deletes expired OAuth authorization codes.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_expired_oauth_authorization_codes()

    Logger.info("Deleted #{count} expired OAuth authorization codes")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.OAuthAuthorizationCode
    alias Portal.Safe

    def delete_expired_oauth_authorization_codes do
      from(c in OAuthAuthorizationCode, as: :codes)
      |> where([codes: c], c.expires_at <= ^DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
