defmodule FzHttp.Mailer.NoopAdapter do
  @moduledoc """
  When mailer is not configure, use noop adapter as a drop-in replacement
  so that we don't have to add conditional logic to every single call to
  `FzHttp.Mailer.deliver/2`.
  """

  use Swoosh.Adapter

  require Logger

  @impl true
  def deliver(email, _opts) do
    Logger.info("Mailer is not configured, dropping email: #{inspect(email)}")
    {:ok, %{}}
  end
end
