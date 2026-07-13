defmodule Portal.Workers.DeleteRotatedGatewayTokens do
  @moduledoc """
  Oban worker that deletes single-owner gateway tokens whose rotation grace
  period has elapsed.

  This is the backstop for abandoned rotations: on the happy path the rotated
  token is deleted as soon as the gateway first connects with its replacement.
  Deleting the token disconnects any gateway still using it via the
  replication delete hook.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Database.delete_rotated_gateway_tokens()

    Logger.info("Deleted #{count} rotated gateway tokens past their grace period")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.GatewayToken
    alias Portal.Safe

    def delete_rotated_gateway_tokens do
      grace_hours = GatewayToken.rotation_grace_hours()
      cutoff = DateTime.add(DateTime.utc_now(), -grace_hours, :hour)

      from(t in GatewayToken, as: :gateway_tokens)
      |> where([gateway_tokens: t], not is_nil(t.device_id))
      |> where([gateway_tokens: t], not is_nil(t.rotated_at))
      |> where([gateway_tokens: t], t.rotated_at <= ^cutoff)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
