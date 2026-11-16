defmodule Portal.Avatars.Prune do
  @moduledoc """
  Oban cron worker that deletes the profile photos no identity links to.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Avatars

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Avatars.enabled?() do
      Avatars.prune()
    end

    :ok
  end
end
