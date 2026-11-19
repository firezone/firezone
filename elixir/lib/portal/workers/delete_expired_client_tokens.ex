defmodule Portal.Workers.DeleteExpiredClientTokens do
  @moduledoc """
  Oban worker that deletes expired tokens.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_expired_client_tokens()

    Logger.info("Deleted #{count} expired client_tokens")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.DeviceToken
    alias Portal.Safe

    # Gateway tokens never expire, so only client tokens match.
    def delete_expired_client_tokens do
      from(t in DeviceToken, where: t.expires_at <= ^DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
