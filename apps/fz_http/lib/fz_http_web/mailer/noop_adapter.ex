defmodule FzHttpWeb.Mailer.NoopAdapter do
  @moduledoc """
  When mailer is not configure, use noop adapter as a drop-in replacement
  so that we don't have to add conditional logic to every single call to
  `FzHttpWeb.Mailer.deliver/2`.
  """

  use Swoosh.Adapter

  require Logger

  @impl true
  def deliver(email, _opts) do
    Logger.info("Mailer is not configured, dropping email: #{inspect(email)}",
      request_id: Keyword.get(Logger.metadata(), :request_id)
    )

    {:ok, %{}}
  end
end
