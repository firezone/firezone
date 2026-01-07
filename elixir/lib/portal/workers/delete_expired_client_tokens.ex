defmodule Portal.Workers.DeleteExpiredClientTokens do
  @moduledoc """
  Oban worker that deletes expired tokens.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias __MODULE__.DB

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = DB.delete_expired_client_tokens()

    Logger.info("Deleted #{count} expired client_tokens")

    :ok
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.ClientToken
    alias Portal.Safe

    def delete_expired_client_tokens do
      from(c in ClientToken, as: :client_tokens)
      |> where([client_tokens: c], c.expires_at <= ^DateTime.utc_now())
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
