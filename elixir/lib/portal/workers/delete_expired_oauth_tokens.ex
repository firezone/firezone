defmodule Portal.Workers.DeleteExpiredOAuthTokens do
  @moduledoc """
  Oban worker that deletes OAuth tokens that can no longer be used or renewed.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_expired_oauth_tokens()

    Logger.info("Deleted #{count} expired OAuth tokens")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.OAuthToken
    alias Portal.Safe

    # The access half expiring is not enough: the row is still what a refresh
    # rotates in place, so it only goes once the refresh window has closed too.
    def delete_expired_oauth_tokens do
      now = DateTime.utc_now()

      from(t in OAuthToken, as: :tokens)
      |> where(
        [tokens: t],
        t.refresh_expires_at <= ^now or
          (is_nil(t.refresh_expires_at) and t.expires_at <= ^now)
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
